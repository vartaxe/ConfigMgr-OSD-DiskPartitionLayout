#!/usr/bin/env python3
"""Check machine-verifiable documentation claims against the repository.

Read-only. Standard library only. Writes nothing.

    python docs_drift.py                     # text report
    python docs_drift.py --repo ../other     # a different repo
    python docs_drift.py --format json
    python docs_drift.py --no-git-root       # scope to one package of a monorepo

Only checks claims that have a definite answer:

  commands   `npm run x`, `make x`, `./scripts/x` in a fenced block, against the
             scripts, targets and files that actually exist
  links      relative Markdown links and images, against the filesystem
  paths      backticked paths, against the filesystem (opt-in, --check-paths)
  env vars   names documented in docs or .env.example, against names actually
             read by the code, in both directions
  staleness  a doc untouched for far longer than the code it describes

It does not judge prose. Wording, tone, completeness and accuracy of explanation
are the reviewing agent's job; this exists so the agent does not spend forty tool
calls confirming whether a path exists.

Backticked-path checking is opt-in. On real repositories most such references are
ambiguous -- a path the doc is telling you to create, or one an archived report
described accurately at the time -- and reporting them buries the findings that
are unambiguous. Markdown links are always checked, because a link is a promise
to resolve.

Values are never read out of environment files. Only the names to the left of `=`
are used, because the right-hand side is a credential by design.
"""

from __future__ import annotations

import argparse
import ast
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

GIT_TIMEOUT = 30
MAX_READ = 2_000_000
STALE_DAYS = 120

SKIP_DIRS = {
    ".git", "node_modules", "vendor", "venv", ".venv", "dist", "build", "target",
    "__pycache__", ".next", "coverage", ".terraform", "site-packages",
}
DOC_EXTS = {".md", ".mdx", ".rst", ".txt"}
CODE_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte",
    ".go", ".rs", ".rb", ".php", ".java", ".kt", ".swift", ".cs", ".ex", ".exs", ".sh",
}
ENV_CODE_EXTS = CODE_EXTS | {".ps1", ".psm1", ".psd1"}

FENCE = re.compile(r"^[ \t]{0,3}(`{3,}|~{3,})")
# Commands worth checking. Anything else in a fenced block is left alone.
CMD_NPM_MANAGER = re.compile(r"(?:npm|pnpm|yarn|bun)(?:\.cmd|\.exe)?", re.I)
NPM_SCRIPT = re.compile(r"[A-Za-z0-9:_.-]+")
SHELL_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*\Z")
NPM_PACKAGE_OPTIONS = {"--prefix", "--cwd", "--dir", "-C"}
NPM_OPTIONS_WITH_VALUE = NPM_PACKAGE_OPTIONS | {
    "--cache", "--globalconfig", "--location", "--loglevel", "--registry",
    "--scope", "--script-shell", "--userconfig", "--workspace", "-w",
}
MAKE_TARGET = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*\Z")
CMD_SCRIPT = re.compile(
    r"(?:^|\s)(\./[A-Za-z0-9_./-]+|"
    r"(?:python3?|node|bash|sh|ruby|pwsh|powershell)\s+"
    r"(?:-File\s+)?([A-Za-z0-9_./-]+\.[A-Za-z0-9]+))", re.I)
CMD_SCRIPT_QUOTED = re.compile(
    r"(?:^|\s)(?:python3?|node|bash|sh|ruby|pwsh|powershell)\s+"
    r"(?:-File\s+)?(['\"])([A-Za-z0-9_./\\ -]+\.[A-Za-z0-9]+)\1", re.I)
CD_COMMAND = re.compile(r"^(?:cd|pushd)\s+(['\"]?)([^'\"]+?)\1\s*$")
POPD_COMMAND = re.compile(r"^popd\s*$")

MD_LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)")
REFERENCE_DEFINITION = re.compile(r"^\s{0,3}\[([^\]]+)\]:\s*(.*)$")
URI_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
BACKTICK = re.compile(r"`([^`\n]+)`")
BACKTICK_RUN = re.compile(r"`+")
MARKDOWN_FENCE = FENCE
FROM_IMPORT_SPEC = re.compile(
    r"^\s*from\s+([A-Za-z0-9_.]+)\s+import\s+([^#\n]+)", re.M)

# Placeholder shapes that are not meant to resolve.
PLACEHOLDER = re.compile(
    r"[<>{}$*]|^\.{3}|\.{3}$|(^|/)(path/to|your[-_][^/]*|my[-_][^/]*|"
    r"example|foo|bar|baz|placeholder)(?=$|/)",
    re.I)

ENV_IN_CODE = [
    re.compile(r"process\.env\.([A-Z][A-Z0-9_]*)"),
    re.compile(r"""process\.env\[\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""os\.environ(?:\.get)?\[?\(?\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""os\.getenv\(\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""os\.Getenv\(\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""os\.LookupEnv\(\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""getenv\(\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""ENV\[\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
    re.compile(r"""Deno\.env\.get\(\s*['"]([A-Z][A-Z0-9_]*)['"]"""),
]
ENV_NAME = re.compile(r"\b([A-Z][A-Z0-9_]{2,})\b")
ENV_SAMPLE_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
POWERSHELL_ENV = re.compile(
    r"(?i)\$(?:env:([A-Za-z_][A-Za-z0-9_]*)|"
    r"\{env:([A-Za-z_][A-Za-z0-9_().-]*)\})")
SHELL_ENV = re.compile(
    r"\$(?:\{([A-Z][A-Z0-9_]*)(?=[:+\-?}=])|([A-Z][A-Z0-9_]*)\b)")

# Import forms across the languages handled above. Four alternatives, so findall
# returns tuples and the caller takes the first non-empty group.
IMPORT_SPEC = re.compile(
    r"""(?:from|import)\s+['"]([^'"]+)['"]"""
    r"""|require\(\s*['"]([^'"]+)['"]\s*\)"""
    r"""|^\s*from\s+([A-Za-z0-9_.]+)\s+import"""
    r"""|^\s*import\s+([A-Za-z0-9_.]+)""",
    re.M)

warnings: list[str] = []


def run_git(args: list[str], cwd: Path) -> str | None:
    git = shutil.which("git")
    if git is None:
        return None
    try:
        p = subprocess.run([git, *args], cwd=str(cwd), text=True, timeout=GIT_TIMEOUT,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           encoding="utf-8", errors="replace")
    except (OSError, subprocess.SubprocessError) as exc:
        warnings.append(f"git {' '.join(args[:2])} failed: {exc}")
        return None
    return p.stdout if p.returncode == 0 else None


def list_files(repo: Path) -> list[str]:
    git = shutil.which("git")
    if git is not None:
        try:
            p = subprocess.run(
                [git, "ls-files", "--cached", "--other", "--exclude-standard", "-z"],
                cwd=str(repo), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=GIT_TIMEOUT)
        except (OSError, subprocess.SubprocessError) as exc:
            warnings.append(f"git ls-files failed: {exc}")
        else:
            if p.returncode == 0 and p.stdout:
                return sorted(
                    name.decode("utf-8", errors="surrogateescape")
                    for name in p.stdout.split(b"\0") if name)
    warnings.append("git unavailable or empty index; walking the filesystem instead")
    files = []
    for root, directories, filenames in os.walk(repo):
        directories[:] = sorted(directory for directory in directories
                                if directory not in SKIP_DIRS)
        root_path = Path(root)
        files.extend(
            (root_path / filename).relative_to(repo).as_posix()
            for filename in filenames
            if (root_path / filename).is_file()
        )
    return sorted(files)


def read(path: Path) -> str:
    try:
        if path.stat().st_size > MAX_READ:
            return ""
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def available_commands(
        repo: Path, files: list[str]) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Real npm scripts and make targets, keyed by the directory that declares them."""
    npm: dict[str, set[str]] = {}
    make: dict[str, set[str]] = {}
    for rel in files:
        base = Path(rel).name
        prefix = str(Path(rel).parent).replace("\\", "/")
        if base == "package.json":
            try:
                data = json.loads(read(repo / rel))
            except ValueError:
                continue
            npm.setdefault(prefix, set())
            if isinstance(data.get("scripts"), dict):
                npm[prefix].update(data["scripts"].keys())
        elif base == "Makefile":
            make[prefix] = makefile_targets(repo, rel)
    return npm, make


def npm_workspace_names(repo: Path, files: list[str]) -> dict[str, set[str]]:
    """Map workspace package names to package directories."""
    names: dict[str, set[str]] = {}
    for rel in files:
        if Path(rel).name != "package.json":
            continue
        try:
            data = json.loads(read(repo / rel))
        except ValueError:
            continue
        name = data.get("name")
        if isinstance(name, str) and name:
            directory = Path(rel).parent.as_posix()
            names.setdefault(name, set()).add(directory)
    return names


def workspace_glob_matches(directory: str, pattern: str) -> bool:
    """Match workspace paths by segment so `*` cannot cross a directory boundary."""
    path_parts = directory.replace("\\", "/").strip("/").split("/")
    normalized_pattern = pattern.replace("\\", "/")
    while normalized_pattern.startswith("./"):
        normalized_pattern = normalized_pattern[2:]
    pattern_parts = normalized_pattern.strip("/").split("/")

    def match(path_index: int, pattern_index: int) -> bool:
        if pattern_index == len(pattern_parts):
            return path_index == len(path_parts)
        if pattern_parts[pattern_index] == "**":
            return (match(path_index, pattern_index + 1)
                    or (path_index < len(path_parts)
                        and match(path_index + 1, pattern_index)))
        return (
            path_index < len(path_parts)
            and fnmatch.fnmatchcase(path_parts[path_index], pattern_parts[pattern_index])
            and match(path_index + 1, pattern_index + 1)
        )

    return bool(path_parts and pattern_parts) and match(0, 0)


def npm_workspaces(repo: Path, npm: dict[str, set[str]],
                   cwd: Path = Path(".")) -> list[set[str]] | None:
    """Resolve workspaces from the nearest package root containing the invocation cwd."""
    invocation_dir = (repo / cwd).resolve()
    repo_root = repo.resolve()
    for root in (invocation_dir, *invocation_dir.parents):
        try:
            root_rel = root.relative_to(repo_root).as_posix()
        except ValueError:
            break
        if root_rel == ".":
            root_rel = ""
        root_package = root / "package.json"
        if not root_package.is_file():
            continue
        try:
            data = json.loads(read(root_package))
        except ValueError:
            continue
        declarations = data.get("workspaces", [])
        if isinstance(declarations, dict):
            declarations = declarations.get("packages", [])
        if not isinstance(declarations, list) or not declarations:
            continue
        patterns = [pattern for pattern in declarations if isinstance(pattern, str)]
        if not patterns or len(patterns) != len(declarations):
            continue
        include = [pattern for pattern in patterns if not pattern.startswith("!")]
        exclude = [pattern[1:] for pattern in patterns if pattern.startswith("!")]
        directories = {
            directory[len(root_rel) + 1:] if root_rel else directory
            for directory in npm
            if directory != root_rel
            and (not root_rel or directory.startswith(root_rel + "/"))
        }
        selected = sorted(
            directory for directory in directories
            if any(workspace_glob_matches(directory, pattern) for pattern in include)
            and not any(workspace_glob_matches(directory, pattern) for pattern in exclude)
        )
        if not selected or any(
                (root_rel + "/" + directory if root_rel else directory) not in npm
                for directory in selected):
            continue
        return [
            npm[root_rel + "/" + directory if root_rel else directory]
            for directory in selected
        ]
    return None


def fenced_blocks(text: str) -> list[tuple[int, str]]:
    """Yield (line_number, line) for lines inside fenced code blocks."""
    return [line for group in fenced_block_groups(text) for line in group]


def fenced_block_groups(text: str) -> list[list[tuple[int, str]]]:
    """Return fenced code lines grouped so shell state does not leak between blocks."""
    groups: list[list[tuple[int, str]]] = []
    current: list[tuple[int, str]] | None = None
    fence_char = ""
    fence_length = 0
    fence_depth = 0
    for i, line in enumerate(text.splitlines(), start=1):
        depth, content = markdown_blockquote_content(line)
        marker = FENCE.match(content)
        if marker and current is None:
            current = []
            groups.append(current)
            fence_char = marker.group(1)[0]
            fence_length = len(marker.group(1))
            fence_depth = depth
        elif current is not None and depth == fence_depth and marker and fence_closes(
                content, marker, fence_char, fence_length):
            current = None
            fence_char = ""
            fence_length = 0
            fence_depth = 0
        elif current is not None:
            current.append((i, markdown_blockquote_content(line, fence_depth)[1]))
    return groups


def markdown_blockquote_content(line: str, depth: int | None = None) -> tuple[int, str]:
    """Strip up to ``depth`` blockquote prefixes and return their count and content."""
    content = line
    count = 0
    while depth is None or count < depth:
        prefix = re.match(r"^[ \t]{0,3}>[ \t]?", content)
        if not prefix:
            break
        content = content[prefix.end():]
        count += 1
    return count, content


def fence_closes(line: str, marker: re.Match[str], fence_char: str,
                 fence_length: int) -> bool:
    """A closing fence may contain only whitespace after its marker."""
    return (marker.group(1)[0] == fence_char
            and len(marker.group(1)) >= fence_length
            and not line[marker.end():].strip())


def directory_from(repo: Path, current: Path, target: str) -> Path | None:
    """Resolve a documented cd/prefix directory without leaving the repository."""
    if dynamic_directory_target(target):
        return None
    target_path = Path(target.replace("\\", "/"))
    candidate = target_path if target_path.is_absolute() else repo / current / target_path
    try:
        return candidate.resolve().relative_to(repo.resolve())
    except (OSError, ValueError):
        return None


def make_directory_from(repo: Path, current: Path, target: str) -> Path | None:
    """Resolve a Make -C directory without falling back to another inventory."""
    if dynamic_directory_target(target):
        return None
    target_path = Path(target.replace("\\", "/"))
    candidate = target_path if target_path.is_absolute() else repo / current / target_path
    try:
        return candidate.resolve().relative_to(repo.resolve())
    except (OSError, ValueError):
        return None


def dynamic_directory_target(target: str) -> bool:
    """Whether a directory operand depends on shell expansion or a placeholder."""
    return (
        target.startswith("~")
        or PLACEHOLDER.search(target) is not None
        or any(char in target for char in "$`*?[]{}<>")
    )


def makefile_targets(repo: Path, rel: str) -> set[str]:
    """Read static target names from one Makefile inventory."""
    target_list = re.compile(
        r"^([A-Za-z0-9][A-Za-z0-9_.-]*(?:[ \t]+[A-Za-z0-9][A-Za-z0-9_.-]*)*):(?!=)",
        re.M)
    return {target for match in target_list.finditer(read(repo / rel))
            for target in match.group(1).split()}


def makefile_inventory_complete(repo: Path, rel: str) -> bool:
    """Whether static target names are sufficient to check negative Make claims."""
    text = read(repo / rel)
    has_pattern_rule = re.search(r"^\s*[^:\n]*%[^:\n]*:", text, re.M)
    has_inclusion = re.search(r"^\s*(?:-?include|sinclude)\s+", text, re.M)
    return not (has_pattern_rule or has_inclusion)


def make_target_has_builtin_rule(repo: Path, cwd: Path, target: str,
                                 rules_enabled: bool = True) -> bool:
    """Avoid rejecting existing targets and common source-to-output built-in rules."""
    target_path = Path(target)
    if (repo / cwd / target_path).is_file():
        return True
    if not rules_enabled:
        return False

    source_suffixes = {
        ".o": (".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".s", ".S",
               ".f", ".F", ".for", ".f90"),
        ".out": (".c", ".cc", ".cpp", ".cxx"),
        "": (".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".f", ".for"),
        ".c": (".y", ".l"),
    }
    for output_suffix, input_suffixes in source_suffixes.items():
        if not output_suffix or target.endswith(output_suffix):
            stem = target[:-len(output_suffix)] if output_suffix else target
            if any((repo / cwd / f"{stem}{suffix}").is_file()
                   for suffix in input_suffixes):
                return True
    return False


def npm_package_scripts(npm: dict[str, set[str]], cwd: Path) -> set[str]:
    """Select scripts from the closest package.json that contains the invocation cwd."""
    applicable = []
    for directory, scripts in npm.items():
        package_dir = Path(directory)
        if cwd == package_dir or package_dir in cwd.parents:
            applicable.append((len(package_dir.parts), scripts))
    return max(applicable, key=lambda item: item[0])[1] if applicable else set()


def npm_workspace_package_scripts(
        repo: Path, npm: dict[str, set[str]], workspace_names: dict[str, set[str]],
        selector: str) -> set[str] | None:
    """Resolve a workspace selector by package directory or package name."""
    target = Path(selector.replace("\\", "/"))
    candidate = target if target.is_absolute() else repo / target
    try:
        directory = candidate.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return None
    if directory in npm:
        return npm[directory]

    matches = workspace_names.get(selector, set())
    if len(matches) == 1:
        return npm.get(next(iter(matches)))
    return None


def documentation_npm_cwd(doc: str, npm: dict[str, set[str]]) -> Path:
    """Use a containing package directory for package-local documentation."""
    doc_dir = Path(doc).parent
    applicable = [
        Path(directory) for directory in npm
        if doc_dir == Path(directory) or Path(directory) in doc_dir.parents
    ]
    return max(applicable, key=lambda directory: len(directory.parts)) if applicable else Path(".")


def shell_tokens(command: str) -> list[str]:
    """Split a shell command on unquoted whitespace while preserving path backslashes."""
    tokens = []
    token = []
    quote = None
    started = False
    index = 0
    while index < len(command):
        char = command[index]
        if quote:
            if char == quote:
                quote = None
            else:
                token.append(char)
            index += 1
        elif char in {'"', "'"}:
            quote = char
            started = True
            index += 1
        elif char == "\\" and index + 1 < len(command) and command[index + 1].isspace():
            token.append(command[index + 1])
            started = True
            index += 2
        elif char.isspace():
            if started:
                tokens.append("".join(token))
                token = []
                started = False
            index += 1
        else:
            token.append(char)
            started = True
            index += 1
    if started:
        tokens.append("".join(token))
    return tokens


def shell_executable_index(tokens: list[str]) -> int | None:
    """Return the command position after simple environment assignments and wrappers."""
    index = 0
    wrappers = {"builtin", "command", "exec", "nohup", "time"}
    while index < len(tokens):
        token = tokens[index]
        if SHELL_ASSIGNMENT.fullmatch(token):
            index += 1
            continue
        if token in wrappers:
            index += 1
            continue
        if token == "env":
            index += 1
            while index < len(tokens):
                token = tokens[index]
                if token == "--":
                    index += 1
                    break
                if token in {"-i", "--ignore-environment"}:
                    index += 1
                    continue
                if token in {"-C", "--chdir"} or token.startswith("--chdir="):
                    return None
                if token in {"-u", "--unset"}:
                    index += 2
                    continue
                if token.startswith("--unset="):
                    index += 1
                    continue
                if SHELL_ASSIGNMENT.fullmatch(token):
                    index += 1
                    continue
                break
            continue
        if token == "sudo":
            index += 1
            while index < len(tokens):
                token = tokens[index]
                if token == "--":
                    index += 1
                    break
                if token in {"-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T"}:
                    index += 2
                    continue
                if token.startswith("-"):
                    index += 1
                    continue
                break
            continue
        if token == "nice":
            index += 1
            if index < len(tokens) and tokens[index] == "-n":
                index += 2
            elif index < len(tokens) and re.fullmatch(r"-\d+", tokens[index]):
                index += 1
            continue
        return index
    return None


def strip_shell_comment(command: str) -> str:
    """Remove a shell comment beginning outside quotes at a token boundary."""
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if char == "\\" and quote != "'":
            index += 2
            continue
        if quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == '"':
                quote = None
        elif char in {'"', "'"}:
            quote = char
        elif char == "#" and (index == 0 or command[index - 1].isspace()):
            return command[:index]
        index += 1
    return command


def shell_segments(command: str) -> list[str]:
    """Split shell command lists without splitting separators in quotes or escapes."""
    segments = []
    start = 0
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\":
            index += 2
            continue
        if quote:
            if char == quote:
                quote = None
            index += 1
            continue
        if char in {'"', "'"}:
            quote = char
            index += 1
            continue
        separator_length = (
            2 if command.startswith(("&&", "||"), index) else
            1 if char == ";" else 0)
        if separator_length:
            segments.append(command[start:index])
            index += separator_length
            while index < len(command) and command[index].isspace():
                index += 1
            start = index
        else:
            index += 1
    segments.append(command[start:])
    return segments


def shell_pipeline_parts(command: str) -> list[str]:
    """Split pipeline stages without splitting quoted or escaped pipe characters."""
    stages = []
    start = 0
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if char == "\\":
            index += 2
            continue
        if quote:
            if char == quote:
                quote = None
            index += 1
            continue
        if char in {'"', "'"}:
            quote = char
            index += 1
            continue
        if char == "|":
            stages.append(command[start:index])
            index += 1
            while index < len(command) and command[index].isspace():
                index += 1
            start = index
        else:
            index += 1
    stages.append(command[start:])
    return stages


def shell_unquoted_text(command: str) -> str:
    """Mask quoted text while retaining positions for command-pattern matching."""
    result = list(command)
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if (char == "\\" and quote != "'" and index + 1 < len(command)
                and command[index + 1] in ";|&\"' \t$"):
            result[index] = " "
            result[index + 1] = " "
            index += 2
            continue
        if quote:
            result[index] = " "
            if char == quote:
                quote = None
            index += 1
            continue
        if char in {'"', "'"}:
            result[index] = " "
            quote = char
        index += 1
    return "".join(result)


def shell_directory_change(
        repo: Path, command: str, cwd: Path | None,
        directory_stack: list[Path | None]
        ) -> tuple[bool, Path | None]:
    """Track cd/pushd/popd while keeping unresolved pushd state unknown."""
    command = command.strip()
    if POPD_COMMAND.fullmatch(command):
        if directory_stack:
            cwd = directory_stack.pop()
        return True, cwd

    cd_match = CD_COMMAND.match(command)
    if not cd_match:
        return False, cwd

    target = cd_match.group(2).strip()
    dynamic_target = dynamic_directory_target(target)
    if command.startswith("pushd"):
        directory_stack.append(cwd)
        if dynamic_target:
            cwd = None
        elif cwd is not None:
            cwd = script_directory_from(repo, cwd, target)
    elif dynamic_target:
        cwd = None
    elif cwd is None:
        target_path = Path(target.replace("\\", "/"))
        cwd = (script_directory_from(repo, None, target)
               if target_path.is_absolute() else None)
    else:
        cwd = directory_from(repo, cwd, target)
    return True, cwd


def npm_commands_in_line(repo: Path, npm: dict[str, set[str]], line: str,
                         cwd: Path | None,
                         workspace_names: dict[str, set[str]] | None = None,
                         directory_stack: list[Path | None] | None = None
                         ) -> tuple[Path | None, list[tuple[str, list[set[str]], bool]]]:
    """Track shell directory changes and retain each selected workspace inventory."""
    commands = []
    line = strip_shell_comment(line)
    directory_stack = directory_stack if directory_stack is not None else []
    for segment in shell_segments(line):
        stages = shell_pipeline_parts(segment)
        is_pipeline = len(stages) > 1
        for stage in stages:
            if not is_pipeline:
                changed, cwd = shell_directory_change(repo, stage, cwd, directory_stack)
                if changed:
                    continue
            tokens = shell_tokens(stage)
            manager_index = shell_executable_index(tokens)
            if manager_index is None or not CMD_NPM_MANAGER.fullmatch(tokens[manager_index]):
                continue
            if cwd is None:
                continue
            arguments = tokens[manager_index + 1:]
            if "--" in arguments:
                arguments = arguments[:arguments.index("--")]
            run_index = None
            i = 0
            while i < len(arguments):
                option = arguments[i]
                if option in NPM_OPTIONS_WITH_VALUE:
                    i += 2
                    continue
                if option.startswith(("--prefix=", "--cwd=", "--dir=")):
                    i += 1
                    continue
                if option.startswith("-"):
                    i += 1
                    continue
                if option == "run":
                    run_index = i
                break
            if run_index is None or run_index + 1 >= len(arguments):
                continue
            script = arguments[run_index + 1]
            if not NPM_SCRIPT.fullmatch(script):
                continue

            prefix = None
            workspace_selectors = []
            all_workspaces = False
            i = 0
            while i < len(arguments):
                option = arguments[i]
                if option.startswith(("--prefix=", "--cwd=", "--dir=")):
                    prefix = option.split("=", 1)[1]
                elif option.startswith(("--workspace=", "-w=")):
                    workspace_selectors.append(option.split("=", 1)[1])
                elif option in {"--workspaces", "--workspaces=true"}:
                    all_workspaces = True
                elif option == "--workspaces=false":
                    all_workspaces = False
                elif option in NPM_PACKAGE_OPTIONS and i + 1 < len(arguments):
                    prefix = arguments[i + 1]
                    i += 1
                elif option in {"--workspace", "-w"} and i + 1 < len(arguments):
                    workspace_selectors.append(arguments[i + 1])
                    i += 1
                i += 1
            command_cwd = directory_from(repo, cwd, prefix) if prefix else cwd
            if command_cwd is None:
                continue
            if_present = "--if-present" in arguments
            if workspace_selectors:
                selected_scripts = []
                resolved = True
                for selector in workspace_selectors:
                    scripts = npm_workspace_package_scripts(
                        repo, npm, workspace_names or {}, selector)
                    if scripts is None:
                        resolved = False
                        break
                    selected_scripts.append(scripts)
                if resolved and selected_scripts:
                    commands.append((script, selected_scripts, if_present))
            elif all_workspaces:
                selected_scripts = npm_workspaces(repo, npm, command_cwd)
                if selected_scripts is not None:
                    commands.append((script, selected_scripts, if_present))
            else:
                commands.append((
                    script, [npm_package_scripts(npm, command_cwd)], if_present))
    return cwd, commands


def make_commands_in_line(
        repo: Path, make: dict[str, set[str]], line: str, cwd: Path | None,
        files: set[str] | None = None,
        directory_stack: list[Path | None] | None = None
        ) -> tuple[Path | None, list[tuple[str, set[str], bool]]]:
    """Track shell directory changes and resolve Make options before collecting targets."""
    commands = []
    line = strip_shell_comment(line)
    directory_stack = directory_stack if directory_stack is not None else []
    for segment in shell_segments(line):
        stages = shell_pipeline_parts(segment)
        is_pipeline = len(stages) > 1
        for stage in stages:
            if not is_pipeline:
                changed, cwd = shell_directory_change(repo, stage, cwd, directory_stack)
                if changed:
                    continue
            tokens = shell_tokens(stage)
            make_index = shell_executable_index(tokens)
            if make_index is None or tokens[make_index] != "make":
                continue
            if cwd is None:
                continue
            arguments = tokens[make_index + 1:]
            make_cwd = cwd
            directory_resolved = True
            required_operand_missing = False
            explicit_makefiles = []
            explicit_makefiles_requested = False
            builtin_rules_enabled = True
            targets = []
            i = 0
            while i < len(arguments):
                option = arguments[i]
                if re.match(r"^(?:\d*(?:>>?|<<?)|&>>?)", option):
                    if re.fullmatch(r"(?:\d*(?:>>?|<<?)|&>>?)", option):
                        i += 2
                    else:
                        i += 1
                    continue
                value = None
                option_name = option
                if option.startswith("--directory="):
                    option_name, value = "--directory", option.split("=", 1)[1]
                elif option.startswith("--file="):
                    option_name, value = "--file", option.split("=", 1)[1]
                elif option.startswith(("--include-dir=", "--old-file=",
                                        "--assume-old=", "--what-if=",
                                        "--new-file=", "--assume-new=")):
                    option_name, value = option.split("=", 1)
                elif option.startswith("--jobs="):
                    option_name, value = "--jobs", option.split("=", 1)[1]
                elif option.startswith("-C") and option != "-C" and not option.startswith("--"):
                    option_name, value = "-C", option[2:]
                elif option.startswith("-f") and option != "-f" and not option.startswith("--"):
                    option_name, value = "-f", option[2:]
                elif option.startswith("-j") and option != "-j" and not option.startswith("--"):
                    option_name, value = "-j", option[2:].lstrip("=")
                elif (option.startswith(("-I", "-o", "-W"))
                      and option[:2] in {"-I", "-o", "-W"}
                      and option != option[:2]
                      and not option.startswith("--")):
                    option_name, value = option[:2], option[2:].lstrip("=")
                elif option.startswith(("-l",)) and option != "-l":
                    option_name, value = "-l", option[2:].lstrip("=")

                if option_name in {"-C", "--directory", "-f", "--file"}:
                    if (value is None and i + 1 < len(arguments)
                            and not arguments[i + 1].startswith("-")):
                        i += 1
                        value = arguments[i]
                    if value:
                        if option_name in {"-C", "--directory"}:
                            resolved = make_directory_from(repo, make_cwd, value)
                            if resolved is None:
                                directory_resolved = False
                            else:
                                make_cwd = resolved
                        else:
                            explicit_makefiles_requested = True
                            explicit_makefiles.append(value)
                    elif option_name in {"-C", "--directory"}:
                        directory_resolved = False
                    else:
                        explicit_makefiles_requested = True
                        required_operand_missing = True
                elif option_name in {
                        "-I", "--include-dir", "-o", "--old-file", "--assume-old",
                        "-W", "--what-if", "--new-file", "--assume-new"}:
                    if value is None and i + 1 < len(arguments):
                        i += 1
                    elif value is None:
                        required_operand_missing = True
                elif option_name in {"-l", "--load-average", "--max-load"}:
                    if value is None and i + 1 < len(arguments):
                        if re.fullmatch(r"\d+(?:\.\d+)?", arguments[i + 1]):
                            i += 1
                elif option_name in {"-j", "--jobs"}:
                    if value is None and i + 1 < len(arguments):
                        next_argument = arguments[i + 1]
                        if next_argument.isdigit():
                            i += 1
                elif option.startswith("-"):
                    if option in {"-r", "-R", "--no-builtin-rules"}:
                        builtin_rules_enabled = False
                elif MAKE_TARGET.fullmatch(option):
                    targets.append(option)
                i += 1

            if not directory_resolved or required_operand_missing:
                continue
            inventory = None
            inventory_complete = True
            if explicit_makefiles_requested and not explicit_makefiles:
                continue
            if explicit_makefiles:
                resolved_makefiles = []
                resolved_completeness = []
                for makefile in explicit_makefiles:
                    makefile_path = Path(makefile.replace("\\", "/"))
                    candidate = (makefile_path if makefile_path.is_absolute()
                                 else repo / make_cwd / makefile_path)
                    try:
                        rel = candidate.resolve().relative_to(repo.resolve()).as_posix()
                    except ValueError:
                        resolved_makefiles = []
                        break
                    if not candidate.is_file() or (
                            files is not None and rel not in files):
                        resolved_makefiles = []
                        break
                    resolved_makefiles.append(makefile_targets(repo, rel))
                    resolved_completeness.append(makefile_inventory_complete(repo, rel))
                if resolved_makefiles:
                    inventory = set().union(*resolved_makefiles)
                    inventory_complete = all(resolved_completeness)
            else:
                inventory = make.get(make_cwd.as_posix())
                inventory_complete = makefile_inventory_complete(
                    repo, (make_cwd / "Makefile").as_posix())
            if inventory is not None:
                for target in targets:
                    applicable_targets = inventory
                    if make_target_has_builtin_rule(
                            repo, make_cwd, target, builtin_rules_enabled):
                        applicable_targets = inventory | {target}
                    commands.append((target, applicable_targets, inventory_complete))
    return cwd, commands


def markdown_lines_without_code(text: str) -> list[tuple[int, str]]:
    """Return Markdown lines with fenced and inline code removed, preserving line numbers."""
    lines = text.splitlines()
    fenced_lines = [False] * len(lines)
    fence_char = ""
    fence_length = 0
    fence_depth = 0
    for i, line in enumerate(lines):
        depth, content = markdown_blockquote_content(line)
        marker = MARKDOWN_FENCE.match(content)
        if fence_char:
            if (depth == fence_depth and marker
                    and fence_closes(content, marker, fence_char, fence_length)):
                fence_char = ""
                fence_length = 0
                fence_depth = 0
            fenced_lines[i] = True
        elif marker:
            fence_char = marker.group(1)[0]
            fence_length = len(marker.group(1))
            fence_depth = depth
            fenced_lines[i] = True
        elif content.startswith(("    ", "\t")):
            fenced_lines[i] = True

    cleaned_lines = [list(line) for line in lines]
    segment_start = 0
    while segment_start < len(lines):
        while segment_start < len(lines) and fenced_lines[segment_start]:
            segment_start += 1
        segment_end = segment_start
        while segment_end < len(lines) and not fenced_lines[segment_end]:
            segment_end += 1

        paragraph_start = segment_start
        while paragraph_start < segment_end:
            while (paragraph_start < segment_end
                   and not lines[paragraph_start].strip()):
                paragraph_start += 1
            if paragraph_start >= segment_end:
                break
            if re.match(
                    r"^[ \t]{0,3}#{1,6}(?:[ \t]+|$)",
                    markdown_blockquote_content(lines[paragraph_start])[1]):
                paragraph_end = paragraph_start + 1
            else:
                paragraph_end = paragraph_start
                while (paragraph_end < segment_end
                       and lines[paragraph_end].strip()
                       and not re.match(
                           r"^[ \t]{0,3}#{1,6}(?:[ \t]+|$)",
                           markdown_blockquote_content(lines[paragraph_end])[1])):
                    paragraph_end += 1

            runs: list[tuple[int, int, int, bool]] = []
            for line_index in range(paragraph_start, paragraph_end):
                line = lines[line_index]
                for match in BACKTICK_RUN.finditer(line):
                    slash_count = 0
                    preceding = match.start() - 1
                    while preceding >= 0 and line[preceding] == "\\":
                        slash_count += 1
                        preceding -= 1
                    runs.append((line_index, match.start(), len(match.group()),
                                 slash_count % 2 == 1))

            run_index = 0
            while run_index < len(runs):
                start_line, start_column, run_length, escaped = runs[run_index]
                if escaped:
                    run_index += 1
                    continue
                closing_index = next((
                    index for index in range(run_index + 1, len(runs))
                    if runs[index][2] == run_length
                ), None)
                if closing_index is None:
                    run_index += 1
                    continue

                end_line, end_column, end_length, _ = runs[closing_index]
                for line_index in range(start_line, end_line + 1):
                    start = start_column if line_index == start_line else 0
                    end = (
                        end_column + end_length
                        if line_index == end_line else len(cleaned_lines[line_index])
                    )
                    cleaned_lines[line_index][start:end] = [" "] * (end - start)
                run_index = closing_index + 1

            paragraph_start = paragraph_end

        segment_start = segment_end

    return [
        (i, "" if fenced_lines[i - 1] else
         markdown_blockquote_content("".join(line))[1])
        for i, line in enumerate(cleaned_lines, start=1)
    ]


def markdown_reference_label(label: str) -> str:
    """Normalize a Markdown reference label for case-insensitive lookup."""
    return re.sub(r"\s+", " ", label).strip().casefold()


def markdown_bracket_end(text: str, start: int) -> int | None:
    """Find a closing bracket while respecting nested brackets and escapes."""
    depth = 0
    index = start
    while index < len(text):
        if text[index] == "\\":
            index += 2
            continue
        if text[index] == "[":
            depth += 1
        elif text[index] == "]":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def markdown_link_destination(
        text: str, start: int, require_closing: bool = True
        ) -> tuple[str, int] | None:
    """Read an inline link destination without truncating balanced parentheses."""
    index = start
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text):
        return None

    if text[index] == "<":
        index += 1
        destination = []
        while index < len(text):
            if text[index] == "\\" and index + 1 < len(text):
                destination.append(text[index + 1])
                index += 2
            elif text[index] == ">":
                index += 1
                break
            else:
                destination.append(text[index])
                index += 1
        else:
            return None
    else:
        destination = []
        depth = 0
        while index < len(text):
            char = text[index]
            if char == "\\" and index + 1 < len(text):
                destination.append(text[index + 1])
                index += 2
            elif char == "(":
                depth += 1
                destination.append(char)
                index += 1
            elif char == ")":
                if depth == 0:
                    if not destination:
                        return None
                    return "".join(destination), index + 1
                depth -= 1
                destination.append(char)
                index += 1
            elif char.isspace() and depth == 0:
                break
            else:
                destination.append(char)
                index += 1

        if depth:
            return None
        if not destination:
            return None

    if not require_closing:
        return "".join(destination), index

    while index < len(text) and text[index].isspace():
        index += 1
    if index < len(text) and text[index] in {'"', "'"}:
        quote = text[index]
        index += 1
        while index < len(text):
            if text[index] == "\\":
                index += 2
            elif text[index] == quote:
                index += 1
                break
            else:
                index += 1
        else:
            return None
        while index < len(text) and text[index].isspace():
            index += 1
    if index >= len(text) or text[index] != ")":
        return None
    return "".join(destination), index + 1


def markdown_image_links(
        text: str, line_number: int, references: dict[str, str]
        ) -> list[tuple[int, str]]:
    """Extract image destinations nested inside a link label."""
    links = []
    index = 0
    while index < len(text):
        image_start = text.find("![", index)
        if image_start < 0:
            break
        closing = markdown_bracket_end(text, image_start + 1)
        if closing is None:
            index = image_start + 2
            continue
        label = text[image_start + 2:closing]
        after = closing + 1
        if after < len(text) and text[after] == "(":
            destination = markdown_link_destination(text, after + 1)
            if destination:
                links.append((line_number, destination[0]))
        elif after < len(text) and text[after] == "[":
            reference_end = markdown_bracket_end(text, after)
            if reference_end is not None:
                reference_label = text[after + 1:reference_end] or label
                target = references.get(markdown_reference_label(reference_label))
                if target:
                    links.append((line_number, target))
        if "!" in label and "[" in label:
            links.extend(markdown_image_links(label, line_number, references))
        index = closing + 1
    return links


def markdown_links(lines: list[tuple[int, str]]) -> list[tuple[int, str]]:
    """Extract inline and reference-style Markdown links from code-free lines."""
    references: dict[str, str] = {}
    definition_lines = set()
    for line_number, line in lines:
        definition = REFERENCE_DEFINITION.match(line)
        if not definition:
            continue
        raw_destination = definition.group(2).strip()
        destination = markdown_link_destination(
            raw_destination, 0, require_closing=False)
        if destination and destination[0]:
            references.setdefault(
                markdown_reference_label(definition.group(1)), destination[0])
            definition_lines.add(line_number)

    links = []
    for line_number, line in lines:
        if line_number in definition_lines:
            continue
        index = 0
        while index < len(line):
            if line[index] == "\\":
                index += 2
                continue
            if line[index] != "[":
                index += 1
                continue
            closing = markdown_bracket_end(line, index)
            if closing is None:
                index += 1
                continue

            label = line[index + 1:closing]
            if "[" in label:
                links.extend(markdown_image_links(label, line_number, references))
            after = closing + 1
            if after < len(line) and line[after] == "(":
                destination = markdown_link_destination(line, after + 1)
                if destination:
                    links.append((line_number, destination[0]))
                index += 1
                continue

            reference = None
            if after < len(line) and line[after] == "[":
                reference_end = markdown_bracket_end(line, after)
                if reference_end is not None:
                    reference_label = line[after + 1:reference_end] or label
                    reference = markdown_reference_label(reference_label)
                    if reference in references:
                        links.append((line_number, references[reference]))
                    index = reference_end + 1
                    continue
            else:
                reference = markdown_reference_label(label)
            if reference in references:
                links.append((line_number, references[reference]))
            index += 1
    return links


def documented_script_exists(repo: Path, doc: str, candidate: str) -> bool:
    """Resolve command paths from the repo, doc directory, or containing skill root."""
    doc_dir = (repo / doc).parent
    candidates = [repo / candidate, doc_dir / candidate]

    current = doc_dir
    while current != repo and repo in current.parents:
        if (current / "SKILL.md").is_file():
            candidates.append(current / candidate)
            break
        current = current.parent

    return any(path.exists() for path in candidates)


def documented_script_relative_path(
        repo: Path, doc: str, candidate: str, invocation_cwd: Path | None,
        explicit_cwd: bool, files: set[str]) -> str | None:
    """Resolve a documented invocation to a scanned repository file."""
    doc_dir = (repo / doc).parent
    if explicit_cwd and invocation_cwd is not None:
        target = Path(candidate.replace("\\", "/"))
        candidates = [target if target.is_absolute()
                      else repo / invocation_cwd / target]
    else:
        candidates = [repo / candidate, doc_dir / candidate]
        current = doc_dir
        while current != repo and repo in current.parents:
            if (current / "SKILL.md").is_file():
                candidates.append(current / candidate)
                break
            current = current.parent
    for path in candidates:
        try:
            relative = path.resolve().relative_to(repo.resolve()).as_posix()
        except (OSError, ValueError):
            continue
        if relative in files and path.is_file():
            return relative
    return None


def script_directory_from(repo: Path, current: Path | None, target: str) -> Path | None:
    """Resolve a literal shell directory without guessing at expansions or external paths."""
    if dynamic_directory_target(target):
        return None

    target_path = Path(target.replace("\\", "/"))
    if not target_path.is_absolute() and current is None:
        return None
    candidate = target_path if target_path.is_absolute() else repo / current / target_path
    try:
        resolved = candidate.resolve()
        relative = resolved.relative_to(repo.resolve())
    except (OSError, ValueError):
        return None
    return relative if resolved.is_dir() else None


def script_commands_in_line(
        repo: Path, line: str, cwd: Path | None, directory_stack: list[Path | None],
        explicit_directory_change: bool
        ) -> tuple[Path | None, list[Path | None], bool,
                   list[tuple[str, Path | None, bool]]]:
    """Track supported shell directory changes and capture script paths at invocation."""
    commands = []
    line = strip_shell_comment(line)
    for segment in shell_segments(line):
        stages = shell_pipeline_parts(segment)
        is_pipeline = len(stages) > 1
        for stage in stages:
            command = stage.strip()
            if not is_pipeline:
                cd_match = CD_COMMAND.match(command)
                if cd_match:
                    target = cd_match.group(2).strip()
                    resolved = script_directory_from(repo, cwd, target)
                    if command.startswith("pushd"):
                        directory_stack.append(cwd)
                    cwd = resolved
                    explicit_directory_change = True
                    continue
                if POPD_COMMAND.fullmatch(command):
                    if directory_stack:
                        cwd = directory_stack.pop()
                    explicit_directory_change = True
                    continue

            tokens = shell_tokens(stage)
            executable_index = shell_executable_index(tokens)
            if executable_index is None:
                continue
            executable = tokens[executable_index]
            candidate = None
            if re.fullmatch(
                    r"(?:python3?|node|bash|sh|ruby|pwsh|powershell)(?:\.cmd|\.exe)?",
                    executable, re.I):
                operand_index = executable_index + 1
                if operand_index < len(tokens) and tokens[operand_index].lower() == "-file":
                    operand_index += 1
                elif operand_index < len(tokens) and tokens[operand_index].startswith("-"):
                    continue
                if operand_index < len(tokens):
                    candidate = tokens[operand_index]
            elif re.fullmatch(r"\./[A-Za-z0-9_./-]+", executable):
                candidate = executable
            if candidate and not PLACEHOLDER.search(candidate):
                commands.append((candidate, cwd, explicit_directory_change))
    return cwd, directory_stack, explicit_directory_change, commands


def script_exists_at(repo: Path, cwd: Path, candidate: str) -> bool:
    """Check a script path relative only to its invocation directory."""
    path = Path(candidate.replace("\\", "/"))
    target = path if path.is_absolute() else repo / cwd / path
    return target.is_file()


def powershell_env_reads(text: str) -> list[tuple[str, int]]:
    """Return PowerShell environment references outside comments and assignments."""
    found: list[tuple[str, int]] = []
    index = 0
    line = 1
    length = len(text)

    while index < length:
        if text[index] == "`":
            if index + 1 < length and text[index + 1] == "\n":
                line += 1
            index += 2
            continue

        if text.startswith("<#", index):
            depth = 1
            index += 2
            while index < length and depth:
                if text.startswith("<#", index):
                    depth += 1
                    index += 2
                elif text.startswith("#>", index):
                    depth -= 1
                    index += 2
                else:
                    if text[index] == "\n":
                        line += 1
                    index += 1
            continue

        char = text[index]
        if char == "#":
            newline = text.find("\n", index)
            if newline == -1:
                break
            index = newline
            continue

        if char == "@" and index + 2 < length and text[index + 1] in "\"'":
            quote = text[index + 1]
            newline = text.find("\n", index + 2)
            if newline != -1 and not text[index + 2:newline].strip():
                index = newline + 1
                line += 1
                terminator = quote + "@"
                while index < length:
                    line_end = text.find("\n", index)
                    if line_end == -1:
                        line_end = length
                    if text.startswith(terminator, index):
                        index = line_end + (line_end < length)
                        if line_end < length:
                            line += 1
                        break
                    if quote == '"':
                        cursor = index
                        while cursor < line_end:
                            if text[cursor] == "`":
                                cursor += 2
                            else:
                                match = POWERSHELL_ENV.match(text, cursor)
                                if match:
                                    found.append((match.group(1) or match.group(2), line))
                                    cursor = match.end()
                                else:
                                    cursor += 1
                    index = line_end + (line_end < length)
                    if line_end < length:
                        line += 1
                continue

        if char == "'":
            index += 1
            while index < length:
                if text.startswith("''", index):
                    index += 2
                elif text[index] == "'":
                    index += 1
                    break
                else:
                    if text[index] == "\n":
                        line += 1
                    index += 1
            continue

        if char == '"':
            index += 1
            while index < length:
                if text[index] == "`":
                    if index + 1 < length and text[index + 1] == "\n":
                        line += 1
                    index += 2
                elif text[index] == '"':
                    index += 1
                    break
                else:
                    match = POWERSHELL_ENV.match(text, index)
                    if match:
                        found.append((match.group(1) or match.group(2), line))
                        index = match.end()
                    else:
                        if text[index] == "\n":
                            line += 1
                        index += 1
            continue

        match = POWERSHELL_ENV.match(text, index)
        if match:
            cursor = match.end()
            while cursor < length and text[cursor] in " \t":
                cursor += 1
            if not text.startswith("=", cursor):
                found.append((match.group(1) or match.group(2), line))
            index = match.end()
        else:
            if char == "\n":
                line += 1
            index += 1

    return found


def shell_env_reads(text: str) -> list[tuple[str, int]]:
    """Return shell parameter expansions outside comments and single-quoted text."""
    found = []
    local_names: set[str] = set()
    for line_number, line in enumerate(text.splitlines(), start=1):
        command = strip_shell_comment(line)
        for segment in shell_segments(command):
            stages = shell_pipeline_parts(segment)
            is_pipeline = len(stages) > 1
            for stage in stages:
                tokens = shell_tokens(stage)
                assignment_tokens = []
                index = 0
                while index < len(tokens) and SHELL_ASSIGNMENT.fullmatch(tokens[index]):
                    assignment_tokens.append(tokens[index])
                    index += 1
                declaration = bool(
                    tokens and tokens[0] in {"export", "local", "declare", "typeset"})
                if declaration:
                    assignment_tokens.extend(
                        token for token in tokens[1:]
                        if SHELL_ASSIGNMENT.fullmatch(token))
                quote = None
                index = 0
                while index < len(stage):
                    char = stage[index]
                    if char == "\\" and quote != "'":
                        index += 2
                        continue
                    if quote == "'":
                        if char == "'":
                            quote = None
                        index += 1
                        continue
                    if quote == '"':
                        if char == '"':
                            quote = None
                            index += 1
                            continue
                    elif char in {'"', "'"}:
                        quote = char
                        index += 1
                        continue

                    match = SHELL_ENV.match(stage, index)
                    if match:
                        name = match.group(1) or match.group(2)
                        if name not in local_names:
                            found.append((name, line_number))
                        index = match.end()
                    else:
                        index += 1
                assignment_only = bool(tokens) and len(assignment_tokens) == len(tokens)
                if not is_pipeline and (declaration or assignment_only):
                    local_names.update(
                        token.split("=", 1)[0] for token in assignment_tokens)
    return found


def python_env_reads(text: str) -> list[tuple[str, int]]:
    """Return Python environment reads from executable AST nodes, not comments or strings."""
    try:
        module = ast.parse(text)
    except (SyntaxError, ValueError):
        return []

    os_aliases = {"os"}
    getenv_aliases = set()
    environ_aliases = set()
    for node in ast.walk(module):
        if isinstance(node, ast.Import):
            for item in node.names:
                if item.name == "os":
                    os_aliases.add(item.asname or "os")
        elif isinstance(node, ast.ImportFrom) and node.module == "os":
            for item in node.names:
                if item.name == "getenv":
                    getenv_aliases.add(item.asname or item.name)
                elif item.name == "environ":
                    environ_aliases.add(item.asname or item.name)

    def environment_expression(node: ast.AST) -> bool:
        return (
            isinstance(node, ast.Name) and node.id in environ_aliases
            or isinstance(node, ast.Attribute)
            and node.attr == "environ"
            and isinstance(node.value, ast.Name)
            and node.value.id in os_aliases
        )

    found = []
    for node in ast.walk(module):
        if isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Subscript):
            target = node.target
            if environment_expression(target.value):
                key = target.slice
                if isinstance(key, ast.Constant) and isinstance(key.value, str):
                    found.append((key.value, node.lineno))
        elif isinstance(node, ast.Call) and node.args:
            function = node.func
            is_getenv = (
                isinstance(function, ast.Name)
                and function.id in getenv_aliases
            ) or (
                isinstance(function, ast.Attribute)
                and function.attr == "getenv"
                and isinstance(function.value, ast.Name)
                and function.value.id in os_aliases
            )
            is_environ_get = (
                isinstance(function, ast.Attribute)
                and function.attr == "get"
                and environment_expression(function.value)
            )
            if is_getenv or is_environ_get:
                name = node.args[0]
                if isinstance(name, ast.Constant) and isinstance(name.value, str):
                    found.append((name.value, node.lineno))
        elif isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load):
            if not environment_expression(node.value):
                continue
            key = node.slice
            if isinstance(key, ast.Constant) and isinstance(key.value, str):
                found.append((key.value, node.lineno))
    return found


def env_names_from_code(repo: Path, files: list[str]) -> dict[str, list[str]]:
    """Env var names the code reads, mapped to every location that reads them."""
    found: dict[str, list[str]] = {}
    for rel in files:
        if Path(rel).suffix not in ENV_CODE_EXTS or any(p in SKIP_DIRS for p in Path(rel).parts):
            continue
        text = read(repo / rel)
        if not text or (
                "env" not in text.lower() and Path(rel).suffix.lower() != ".sh"):
            continue
        if Path(rel).suffix.lower() in {".ps1", ".psm1", ".psd1"}:
            for name, line in powershell_env_reads(text):
                found.setdefault(name, []).append(f"{rel}:{line}")
            continue
        if Path(rel).suffix.lower() == ".py":
            for name, line in python_env_reads(text):
                found.setdefault(name, []).append(f"{rel}:{line}")
            continue
        for i, line in enumerate(text.splitlines(), start=1):
            names = [name for pattern in ENV_IN_CODE for name in pattern.findall(line)]
            for name in names:
                found.setdefault(name, []).append(f"{rel}:{i}")
        if Path(rel).suffix.lower() == ".sh":
            for name, line in shell_env_reads(text):
                found.setdefault(name, []).append(f"{rel}:{line}")
    return found


def unreferenced_modules(repo: Path, files: list[str],
                         documented_entrypoints: set[str] | None = None) -> set[str]:
    """Code files that nothing imports, and that are not plausible entrypoints.

    A documented setting read only inside such a file is configuration that cannot
    take effect, which reads as working config in the docs. Deliberately
    conservative: basename matching, and anything entrypoint-shaped is excluded, so
    it under-reports rather than accusing live code of being dead.
    """
    code = [f for f in files
            if Path(f).suffix in CODE_EXTS and Path(f).suffix.lower() != ".go"
            and Path(f).suffix.lower() != ".sh"
            and not any(p in SKIP_DIRS for p in Path(f).parts)]
    entrypoint = re.compile(
        r"(^|/)(server|main|index|app|cli|__init__|__main__|conftest|setup|wsgi|asgi)\.[A-Za-z]+$",
        re.I)
    imported: set[str] = set()
    guarded_entrypoints: set[str] = set()
    for rel in code:
        text = read(repo / rel)
        if not text:
            continue
        if Path(rel).suffix.lower() == ".py" and has_python_main_guard(text):
            guarded_entrypoints.add(rel)
        for groups in IMPORT_SPEC.findall(text):
            ref = next((g for g in groups if g), "").strip()
            if not ref:
                continue
            imported.add(Path(ref).name.lower())
            imported.add(Path(ref).stem.lower())
            for part in re.split(r"[./\:]", ref):
                if part:
                    imported.add(part.lower())
        for match in FROM_IMPORT_SPEC.finditer(text):
            for item in match.group(2).strip().strip("()").split(","):
                name = item.strip().split(" as ", 1)[0].strip()
                if name and name != "*":
                    imported.add(Path(name).name.lower())
                    imported.add(Path(name).stem.lower())
    out = set()
    for rel in code:
        if documented_entrypoints and rel in documented_entrypoints:
            continue
        if rel in guarded_entrypoints or entrypoint.search(rel):
            continue
        stem = Path(rel).stem.lower()
        if stem not in imported and Path(rel).name.lower() not in imported:
            out.add(rel)
    return out


def has_python_main_guard(text: str) -> bool:
    """Whether Python source has a top-level ``if __name__ == "__main__"`` guard."""
    try:
        module = ast.parse(text)
    except (SyntaxError, ValueError):
        return False

    for statement in module.body:
        if not isinstance(statement, ast.If):
            continue
        test = statement.test
        if not (isinstance(test, ast.Compare)
                and len(test.ops) == 1
                and isinstance(test.ops[0], ast.Eq)
                and len(test.comparators) == 1):
            continue
        left, right = test.left, test.comparators[0]
        if ((isinstance(left, ast.Name) and left.id == "__name__"
             and isinstance(right, ast.Constant) and right.value == "__main__")
                or (isinstance(right, ast.Name) and right.id == "__name__"
                    and isinstance(left, ast.Constant) and left.value == "__main__")):
            return True
    return False


def env_names_documented(repo: Path, files: list[str],
                         code_names: set[str] | None = None) -> dict[str, str]:
    """Env var names named in docs or declared in an env sample file.

    Only the key to the left of `=` is ever read from an env file. The value is a
    credential by design and is never touched.
    """
    documented: dict[str, str] = {}
    for rel in files:
        base = Path(rel).name
        is_env_sample = (
            base.startswith(".env.")
            and base.rsplit(".", 1)[-1].lower()
            in {"example", "sample", "template", "dist", "defaults"}
        )
        if not is_env_sample and Path(rel).suffix not in DOC_EXTS:
            continue
        text = read(repo / rel)
        if not text:
            continue
        for i, line in enumerate(text.splitlines(), start=1):
            if is_env_sample:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or "=" not in stripped:
                    continue
                key = stripped.split("=", 1)[0].strip()
                if key.startswith("export "):
                    key = key[len("export "):].strip()
                if ENV_SAMPLE_NAME.fullmatch(key or ""):
                    documented.setdefault(key, f"{rel}:{i}")
            else:
                # In prose, a backticked all-caps token is weak evidence: `SKILL.md`
                # and `README` are not configuration. Require an underscore, which is
                # what actually distinguishes API_TOKEN from a shouted word, and skip
                # anything that looks like a filename.
                for chunk in BACKTICK.findall(line):
                    if "." in chunk or "/" in chunk:
                        continue
                    for name in ENV_NAME.findall(chunk):
                        if "_" not in name and (
                                code_names is None or name not in code_names):
                            continue
                        documented.setdefault(name, f"{rel}:{i}")
                for match in POWERSHELL_ENV.finditer(line):
                    name = match.group(1) or match.group(2)
                    documented.setdefault(name, f"{rel}:{i}")
    return documented


def newest_commit_epoch(repo: Path, pathspec: str) -> int | None:
    out = run_git(["log", "-1", "--format=%at", "--", pathspec], repo)
    if not out or not out.strip().isdigit():
        return None
    return int(out.strip())


def build(repo: Path, files: list[str], check_paths: bool = False) -> dict:
    findings: list[dict] = []

    def add(kind: str, severity: str, doc: str, line: int | None, detail: str,
            source: str | None = None) -> None:
        findings.append({"kind": kind, "severity": severity, "doc": doc, "line": line,
                         "detail": detail, "source": source})

    file_set = set(files)
    npm_scripts, make_targets = available_commands(repo, files)
    workspace_names = npm_workspace_names(repo, files)
    all_npm = set().union(*npm_scripts.values()) if npm_scripts else set()
    docs = [f for f in files
            if Path(f).suffix in DOC_EXTS and not any(p in SKIP_DIRS for p in Path(f).parts)]
    documented_entrypoints: set[str] = set()

    for doc in docs:
        text = read(repo / doc)
        if not text:
            continue

        # 1. commands
        for block in fenced_block_groups(text):
            npm_cwd = documentation_npm_cwd(doc, npm_scripts)
            npm_directory_stack: list[Path | None] = []
            make_cwd = Path(".")
            make_directory_stack: list[Path | None] = []
            script_cwd = Path(".")
            script_directory_stack: list[Path] = []
            explicit_script_directory_change = False
            for lineno, line in block:
                npm_cwd, npm_calls = npm_commands_in_line(
                    repo, npm_scripts, line, npm_cwd, workspace_names,
                    npm_directory_stack)
                unique_npm_calls = {
                    (script, tuple(frozenset(scripts) for scripts in inventories), if_present)
                    for script, inventories, if_present in npm_calls
                }
                for script, inventory_keys, if_present in unique_npm_calls:
                    if not npm_scripts or if_present:
                        continue
                    applicable_scripts = set().union(*inventory_keys)
                    if any(script not in scripts for scripts in inventory_keys):
                        near = ", ".join(sorted(
                            s for s in applicable_scripts
                            if s.startswith(script.split(":")[0]))[:4])
                        hint = f" Closest existing: {near}." if near else ""
                        add("missing-script", "high", doc, lineno,
                            f"documents `{script}`, which is not a script in every applicable "
                            f"package.json.{hint}", source="package.json")
                make_cwd, make_calls = make_commands_in_line(
                    repo, make_targets, line, make_cwd, file_set,
                    make_directory_stack)
                for target, applicable_targets, complete in set(
                        (target, frozenset(targets), complete)
                        for target, targets, complete in make_calls):
                    if not complete:
                        continue
                    if target not in applicable_targets:
                        add("missing-make-target", "high", doc, lineno,
                            f"documents `make {target}`, which is not a target in the "
                            "Makefile at the invocation directory.",
                            source="Makefile")
                (script_cwd, script_directory_stack,
                 explicit_script_directory_change, script_calls) = script_commands_in_line(
                    repo, line, script_cwd, script_directory_stack,
                    explicit_script_directory_change)
                for candidate, invocation_cwd, explicit_cwd in script_calls:
                    entrypoint = documented_script_relative_path(
                        repo, doc, candidate, invocation_cwd, explicit_cwd, file_set)
                    if entrypoint:
                        documented_entrypoints.add(entrypoint)
                    if (invocation_cwd is None or candidate.endswith("/")
                            or any(part in SKIP_DIRS for part in Path(candidate).parts)):
                        continue
                    exists = (
                        script_exists_at(repo, invocation_cwd, candidate)
                        if explicit_cwd else
                        candidate in file_set or documented_script_exists(repo, doc, candidate)
                    )
                    if not exists:
                        add("missing-script-file", "high", doc, lineno,
                            f"documents running `{candidate}`, which does not exist.")

        # 2 and 3. links and backticked paths
        for i, target in markdown_links(markdown_lines_without_code(text)):
            local_target = target.split("#", 1)[0].split("?", 1)[0].strip()
            t = unquote(local_target)
            if not t or URI_SCHEME.match(t) or t.startswith(("//", "#")):
                continue
            if PLACEHOLDER.search(t):
                continue
            target_path = Path(t.lstrip("/")) if t.startswith("/") else Path(doc).parent / t
            if not (repo / target_path).exists():
                add("broken-link", "high", doc, i,
                    f"relative link `{t}` does not resolve.")
        for i, line in enumerate(text.splitlines(), start=1):
            for chunk in (BACKTICK.findall(line) if check_paths else []):
                c = chunk.strip()
                # Only treat it as a path claim when it looks like one.
                if "/" not in c or " " in c or PLACEHOLDER.search(c):
                    continue
                # A leading slash means a slash-command or an absolute path, e.g.
                # `/security-review`. Neither is a claim about this repository.
                if c.startswith("/"):
                    continue
                if not re.match(r"^[A-Za-z0-9._/-]+$", c) or c.endswith("/"):
                    continue
                # Require a real file extension. Extensionless slashed tokens are
                # ambiguous by nature -- `origin/staging` is a git ref, `src/utils/billing`
                # is an illustrative example, `@scope/pkg` is a package. Accusing those
                # of being broken paths produced far more noise than signal.
                if not re.match(r"^\.[A-Za-z0-9]{1,5}$", Path(c).suffix):
                    continue
                if c in file_set or (repo / c).exists():
                    continue
                # Docs routinely write paths relative to their own directory.
                if (repo / Path(doc).parent / c).exists():
                    continue
                # A directory prefix that exists is close enough not to report.
                if any(f.startswith(c.rstrip("/") + "/") for f in file_set):
                    continue
                # Docs also reference a shape that repeats, e.g. `agents/openai.yaml`
                # when the real files are skills/<name>/agents/openai.yaml. If it is
                # the tail of a real path, the claim is true enough.
                tail = "/" + c
                if any(f.endswith(tail) for f in file_set):
                    continue
                add("missing-path", "medium", doc, i,
                    f"references `{c}`, which does not exist in the repository.")

    # 4. env vars, both directions
    in_code = env_names_from_code(repo, files)
    in_docs = env_names_documented(repo, files, set(in_code))
    dead = unreferenced_modules(repo, files, documented_entrypoints)

    for name, where in sorted(in_docs.items()):
        readers = in_code.get(name, [])
        doc_path, _, doc_line = where.rpartition(":")
        if not readers:
            add("documented-unused-env", "medium", doc_path, int(doc_line),
                f"`{name}` is documented but nothing in the code reads it. "
                "Either it is dead configuration or the docs promise a knob that does not exist.",
                source="no reader found")
        elif all(r.rsplit(":", 1)[0] in dead for r in readers):
            where_read = ", ".join(readers[:3])
            add("documented-env-in-unreferenced-module", "medium", doc_path, int(doc_line),
                f"`{name}` is read only in a module nothing imports, so the documented setting "
                "cannot take effect. The docs describe a working knob that does nothing.",
                source=where_read)
    for name, readers in sorted(in_code.items()):
        documented = name in in_docs
        if not documented:
            add("undocumented-env", "medium", "(docs)", None,
                f"`{name}` is read by the code but is not documented anywhere, "
                "and is not in an env sample file.",
                source=readers[0])

    # 5. staleness
    code_dirs = {str(Path(f).parent).replace("\\", "/") for f in files
                 if Path(f).suffix in CODE_EXTS}
    newest_code = max((e for e in (newest_commit_epoch(repo, d) for d in list(code_dirs)[:40])
                       if e), default=None)
    if newest_code:
        for doc in docs:
            doc_epoch = newest_commit_epoch(repo, doc)
            if not doc_epoch:
                continue
            days = (newest_code - doc_epoch) / 86400
            if days > STALE_DAYS:
                add("stale-doc", "low", doc, None,
                    f"last changed {int(days)} days before the most recent code change. "
                    "Not wrong by itself, but worth reading against current behavior.")

    order = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: (order.get(f["severity"], 3), f["doc"], f["line"] or 0))
    return {
        "repo": str(repo),
        "totals": {"docs_checked": len(docs), "findings": len(findings),
                   "npm_scripts_found": len(all_npm), "make_targets_found": len(make_targets),
                   "env_names_in_code": len(in_code), "env_names_documented": len(in_docs)},
        "findings": findings,
        "warnings": warnings,
    }


def render(d: dict, top: int) -> str:
    t = d["totals"]
    L = ["# Documentation Drift Check", "", f"Repo: {d['repo']}",
         f"Docs checked: {t['docs_checked']}   Findings: {t['findings']}",
         f"Known npm scripts: {t['npm_scripts_found']}   make targets: {t['make_targets_found']}",
         f"Env names in code: {t['env_names_in_code']}   documented: {t['env_names_documented']}", ""]

    if not d["findings"]:
        L.append("No machine-verifiable drift found. Prose accuracy is still unchecked.")
    else:
        shown = d["findings"][:top]
        if len(d["findings"]) > top:
            L.append(f"TRUNCATED: showing {top} of {len(d['findings'])} findings")
            L.append("")
        for f in shown:
            loc = f"{f['doc']}:{f['line']}" if f.get("line") else f["doc"]
            L.append(f"- [{f['severity']}] {f['kind']} -- {loc}")
            L.append(f"  {f['detail']}")
            if f.get("source"):
                L.append(f"  source of truth: {f['source']}")
    L.append("")
    if d["warnings"]:
        L.append("## Warnings")
        L.extend(f"- {w}" for w in d["warnings"])
        L.append("")
    L.append("Checks only claims with a definite answer. Wording, completeness and whether an")
    L.append("explanation is actually correct are not checked here. Confirm each finding by")
    L.append("opening both the doc and the source before reporting it.")
    return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(description="Check documentation claims against the repo. Read-only.")
    ap.add_argument("--repo", default=".", help="Path inside the repository.")
    ap.add_argument("--format", choices=["text", "json"], default="text", help="Output format.")
    ap.add_argument("--top", type=int, default=30, help="Findings to show. Default 30.")
    ap.add_argument("--check-paths", action="store_true",
                    help=("Also check backticked paths against the filesystem. Off by default: on "
                          "real repos most such references are ambiguous -- a path a doc tells you "
                          "to create, or one an archived report described at the time -- and the "
                          "noise buries the unambiguous findings. Markdown links are always checked."))
    ap.add_argument("--no-git-root", action="store_true",
                    help="Treat --repo literally instead of expanding to the enclosing git repository root.")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        print(f"error: not a directory: {repo}", file=sys.stderr)
        return 2
    if not args.no_git_root:
        root = run_git(["rev-parse", "--show-toplevel"], repo)
        if root and root.strip():
            repo = Path(root.strip()).resolve()

    files = list_files(repo)
    if not files:
        print(f"error: no files found under {repo}", file=sys.stderr)
        return 2

    data = build(repo, files, check_paths=args.check_paths)
    print(json.dumps(data, indent=2) if args.format == "json" else render(data, args.top))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
