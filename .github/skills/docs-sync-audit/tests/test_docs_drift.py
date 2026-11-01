import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "docs_drift.py"
SPEC = importlib.util.spec_from_file_location("docs_drift", SCRIPT_PATH)
DOCS_DRIFT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCS_DRIFT)


class DocsDriftTests(unittest.TestCase):
    def test_go_getenv_and_lookupenv_prevent_unused_env_finding(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.go").write_text(
                'token := os.Getenv("API_TOKEN")\n'
                '_, found := os.LookupEnv("API_TOKEN")\n',
                encoding="utf-8")
            (repo / "README.md").write_text(
                "Configure `API_TOKEN` before running the service.\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["main.go", "README.md"])

            self.assertNotIn(
                "documented-unused-env",
                {finding["kind"] for finding in result["findings"]})
            self.assertEqual(
                DOCS_DRIFT.env_names_from_code(repo, ["main.go"])["API_TOKEN"],
                ["main.go:1", "main.go:2"])

    def test_powershell_env_writes_and_comments_are_not_reads(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            script = repo / "settings.ps1"
            script.write_text(
                '$env:ASSIGN_ONLY = "configured"\n'
                '# $env:LINE_COMMENT\n'
                '<# $env:BLOCK_COMMENT\n'
                '   <# $env:NESTED_COMMENT #>\n'
                '   $env:BLOCK_COMMENT_TOO #>\n'
                "Write-Output '$env:SINGLE_QUOTED'\n"
                'Write-Output $env:ACTUAL_READ\n'
                'Write-Output "expanded=$env:EXPANDED_READ"\n',
                encoding="utf-8")

            env_names = DOCS_DRIFT.env_names_from_code(repo, ["settings.ps1"])

            self.assertEqual(
                env_names,
                {
                    "ACTUAL_READ": ["settings.ps1:7"],
                    "EXPANDED_READ": ["settings.ps1:8"],
                })

    def test_powershell_escaped_env_references_are_not_reads(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            script = repo / "settings.ps1"
            script.write_text(
                'Write-Output `$env:ESCAPED_UNQUOTED\n'
                'Write-Output "`$env:ESCAPED_EXPANDED"\n'
                'Write-Output $env:ACTUAL_READ\n'
                'Write-Output "expanded=$env:EXPANDED_READ"\n',
                encoding="utf-8")

            self.assertEqual(
                DOCS_DRIFT.env_names_from_code(repo, ["settings.ps1"]),
                {
                    "ACTUAL_READ": ["settings.ps1:3"],
                    "EXPANDED_READ": ["settings.ps1:4"],
                })

    def test_powershell_compound_assignments_and_increments_are_reads(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            script = repo / "settings.ps1"
            script.write_text(
                '$env:ADD += 1\n'
                '$env:SUBTRACT -= 1\n'
                '$env:MULTIPLY *= 2\n'
                '$env:DIVIDE /= 2\n'
                '$env:MODULO %= 2\n'
                '$env:COALESCE ??= 1\n'
                '$env:POSTFIX++\n'
                '--$env:PREFIX\n'
                '$env:ASSIGN = 1\n',
                encoding="utf-8")

            self.assertEqual(
                DOCS_DRIFT.env_names_from_code(repo, ["settings.ps1"]),
                {
                    "ADD": ["settings.ps1:1"],
                    "SUBTRACT": ["settings.ps1:2"],
                    "MULTIPLY": ["settings.ps1:3"],
                    "DIVIDE": ["settings.ps1:4"],
                    "MODULO": ["settings.ps1:5"],
                    "COALESCE": ["settings.ps1:6"],
                    "POSTFIX": ["settings.ps1:7"],
                    "PREFIX": ["settings.ps1:8"],
                })

    def test_env_sample_strips_only_export_prefix_and_preserves_key_case(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            sample = repo / ".env.example"
            sample.write_text(
                "export FOO=secret\n"
                "exported=secret\n"
                "MiXeD_KEY=secret\n",
                encoding="utf-8")

            self.assertEqual(
                DOCS_DRIFT.env_names_documented(repo, [".env.example"]),
                {
                    "FOO": ".env.example:1",
                    "exported": ".env.example:2",
                    "MiXeD_KEY": ".env.example:3",
                })

    def test_skill_context_inline_code_and_powershell_env(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            skill_root = repo / ".github" / "skills" / "copilot-pr-autopilot"
            references = skill_root / "references"
            scripts = skill_root / "scripts"
            references.mkdir(parents=True)
            scripts.mkdir()
            (skill_root / "SKILL.md").write_text("# Skill\n", encoding="utf-8")
            env_prefix = chr(36) + "env:"
            (scripts / "02-check-review-status.ps1").write_text(
                f"{env_prefix}windir; {env_prefix}SystemDrive; {env_prefix}COMPUTERNAME\n",
                encoding="utf-8")
            doc = references / "01-request-review.md"
            doc.write_text(
                """# Review

```powershell
pwsh ./scripts/02-check-review-status.ps1
python .github/scripts/check.py
[Fake](not-a-real-link.md)
```

PowerShell cast: `[Security.Principal.WindowsIdentity]::GetCurrent(`.
PowerShell environment: `$env:COMPUTERNAME`.

[Repo root link](/assets/file%20with%20spaces.md)
`[example](not-a-real-multiline-link.md)
continues inside this code span`
`This unmatched delimiter must not hide a real link
[Real broken link](missing.md)
""",
                encoding="utf-8")
            assets = repo / "assets"
            assets.mkdir()
            (assets / "file with spaces.md").write_text("# Valid target\n", encoding="utf-8")
            scripts = repo / ".github" / "scripts"
            scripts.mkdir(parents=True)
            (scripts / "check.py").write_text("print('ok')\n", encoding="utf-8")
            docs = repo / "docs"
            guides = docs / "guides"
            guides.mkdir(parents=True)
            (docs / "scripts").mkdir()
            (docs / "scripts" / "check.py").write_text("print('ok')\n", encoding="utf-8")
            (guides / "setup.md").write_text(
                "```bash\npython ../scripts/check.py\n```\n", encoding="utf-8")
            encoded_link_doc = docs / "links.md"
            encoded_link_doc.write_text(
                "[Encoded link](../assets/file%20with%20spaces.md?plain=1#usage)\n",
                encoding="utf-8")
            files = [
                ".github/skills/copilot-pr-autopilot/SKILL.md",
                ".github/skills/copilot-pr-autopilot/references/01-request-review.md",
                ".github/skills/copilot-pr-autopilot/scripts/02-check-review-status.ps1",
                "assets/file with spaces.md",
                ".github/scripts/check.py",
                "docs/scripts/check.py",
                "docs/guides/setup.md",
                "docs/links.md",
            ]

            result = DOCS_DRIFT.build(repo, files)
            findings = result["findings"]
            self.assertFalse(any(f["kind"] == "missing-script-file" for f in findings))
            broken_links = [f["detail"] for f in findings if f["kind"] == "broken-link"]
            self.assertEqual(len(broken_links), 1)
            self.assertIn("missing.md", broken_links[0])
            self.assertNotIn("not-a-real-link.md", " ".join(broken_links))
            self.assertNotIn("not-a-real-multiline-link.md", " ".join(broken_links))
            self.assertNotIn("Fake", " ".join(broken_links))
            self.assertIn("COMPUTERNAME", DOCS_DRIFT.env_names_documented(repo, files))

            env_names = DOCS_DRIFT.env_names_from_code(repo, files)
            self.assertEqual(set(env_names), {"windir", "SystemDrive", "COMPUTERNAME"})

    def test_inline_code_pairs_equal_length_delimiters(self):
        text = "`one ``two` three`` four`"

        cleaned = DOCS_DRIFT.markdown_lines_without_code(text)

        self.assertEqual(
            cleaned[0][1],
            " " * len("`one ``two`") + " three`` four`")

    def test_escaped_inline_code_delimiter_is_not_an_opener(self):
        text = r"\`escaped ` [Broken](missing.md)"

        cleaned = DOCS_DRIFT.markdown_lines_without_code(text)

        self.assertEqual(cleaned[0][1], text)

    def test_escaped_matching_backtick_closes_an_active_span(self):
        text = r"`x\` [Broken](missing.md) `later`"

        cleaned = DOCS_DRIFT.markdown_lines_without_code(text)

        self.assertIn("[Broken](missing.md)", cleaned[0][1])
        self.assertEqual(
            DOCS_DRIFT.MD_LINK.findall(cleaned[0][1]), ["missing.md"])
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "README.md").write_text(text, encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["README.md"])

            self.assertIn(
                "broken-link",
                {finding["kind"] for finding in result["findings"]})

    def test_unmatched_inline_code_does_not_pair_across_paragraphs(self):
        text = "`unmatched opener\n\n[Broken](missing.md) `"

        cleaned = DOCS_DRIFT.markdown_lines_without_code(text)

        self.assertEqual(
            [line for _, line in cleaned],
            ["`unmatched opener", "", "[Broken](missing.md) `"])

    def test_powershell_env_matching_is_case_insensitive_in_build(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.ps1").write_text(
                'Write-Output $env:foo\n', encoding="utf-8")
            (repo / "README.md").write_text(
                "PowerShell environment: `$env:FOO`.\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["main.ps1", "README.md"])
            env_findings = [
                finding for finding in result["findings"]
                if finding["kind"] in {"documented-unused-env", "undocumented-env"}
            ]

            self.assertEqual(env_findings, [])

    def test_powershell_env_same_case_matches_in_build(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.ps1").write_text(
                'Write-Output $ENV:foo\n', encoding="utf-8")
            (repo / "README.md").write_text(
                "PowerShell environment: `$env:foo`.\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["main.ps1", "README.md"])

            self.assertNotIn(
                "documented-unused-env",
                {finding["kind"] for finding in result["findings"]})
            self.assertNotIn(
                "undocumented-env",
                {finding["kind"] for finding in result["findings"]})

    def test_braced_powershell_env_reads_match_docs_and_filter_assignment(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.ps1").write_text(
                '$env:ASSIGN_ONLY = "configured"\n'
                'Write-Output ${env:API_TOKEN}\n'
                'Write-Output "expanded=${env:HOST}"\n'
                '# ${env:COMMENT_ONLY}\n',
                encoding="utf-8")
            (repo / "README.md").write_text(
                "Configure `$env:API_TOKEN` and `$env:HOST`.\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["main.ps1", "README.md"])

            env_names = DOCS_DRIFT.env_names_from_code(repo, ["main.ps1"])
            self.assertEqual(set(env_names), {"API_TOKEN", "HOST"})
            self.assertNotIn(
                "documented-unused-env",
                {finding["kind"] for finding in result["findings"]})
            self.assertNotIn(
                "undocumented-env",
                {finding["kind"] for finding in result["findings"]})

    def test_unix_environment_matching_remains_case_sensitive(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.py").write_text(
                "import os\nos.getenv('PORT')\n", encoding="utf-8")
            (repo / "README.md").write_text(
                "The setting `$env:port` is supported.\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["main.py", "README.md"])
            env_findings = [
                finding for finding in result["findings"]
                if finding["kind"] in {"documented-unused-env", "undocumented-env"}
            ]

            self.assertEqual(
                {finding["kind"] for finding in env_findings},
                {"documented-unused-env", "undocumented-env"})

    def test_backticked_single_word_env_names_match_only_code_reads(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.js").write_text(
                "process.env.PORT; process.env.HOST; process.env.DEBUG;\n",
                encoding="utf-8")
            (repo / "README.md").write_text(
                "Configure `PORT`, `HOST`, and `DEBUG`; ignore `WINGSPAN`.\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["main.js", "README.md"])

            self.assertNotIn(
                "documented-unused-env",
                {finding["kind"] for finding in result["findings"]})
            self.assertNotIn(
                "undocumented-env",
                {finding["kind"] for finding in result["findings"]})

    def test_env_reads_are_scoped_to_powershell_and_shell_sources(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "example.py").write_text(
                '# $env:PY_COMMENT\nvalue = "$env:PY_STRING"\n',
                encoding="utf-8")
            (repo / "test_example.py").write_text(
                'fixture = "$env:TEST_STRING"\n', encoding="utf-8")
            (repo / "main.sh").write_text(
                "# $COMMENT_ONLY\n"
                "echo '$SINGLE_QUOTED'\n"
                'echo "$API_TOKEN"\n'
                "echo ${HOST}\n",
                encoding="utf-8")
            (repo / "README.md").write_text(
                "Configure `API_TOKEN` and `HOST`.\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["example.py", "test_example.py", "main.sh", "README.md"])

            env_names = DOCS_DRIFT.env_names_from_code(
                repo, ["example.py", "test_example.py", "main.sh"])
            self.assertEqual(set(env_names), {"API_TOKEN", "HOST"})
            self.assertNotIn(
                "documented-unused-env",
                {finding["kind"] for finding in result["findings"]})
            self.assertNotIn(
                "undocumented-env",
                {finding["kind"] for finding in result["findings"]})

    def test_script_path_uses_cd_working_directory_across_lines(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "tools").mkdir()
            doc = repo / "README.md"
            doc.write_text(
                "```sh\ncd tools\npython scripts/build.py\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["README.md"])

            missing = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script-file"
            ]
            self.assertEqual(len(missing), 1)
            self.assertEqual(missing[0]["line"], 3)

    def test_script_path_uses_cd_working_directory_on_same_line(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "tools").mkdir()
            doc = repo / "README.md"
            doc.write_text(
                "```sh\ncd tools && python scripts/build.py\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["README.md"])

            self.assertIn(
                "missing-script-file",
                {finding["kind"] for finding in result["findings"]})

    def test_power_shell_script_invocations_without_dot_slash_are_checked(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            doc = repo / "README.md"
            doc.write_text(
                "```powershell\n"
                "pwsh scripts/missing.ps1\n"
                "powershell -File scripts/also-missing.ps1\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["README.md"])
            missing = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script-file"
            ]

            self.assertEqual(len(missing), 2)

    def test_placeholder_names_are_matched_at_component_boundaries(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            doc = repo / "README.md"
            doc.write_text(
                "[examples](examples/missing.md) "
                "[foobar](foobar/missing.md) "
                "[placeholder data](placeholder-data/missing.md) "
                "[example placeholder](example/missing.md)\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["README.md"])
            broken = [
                finding["detail"] for finding in result["findings"]
                if finding["kind"] == "broken-link"
            ]

            self.assertEqual(len(broken), 3)
            self.assertTrue(any("examples/missing.md" in item for item in broken))
            self.assertTrue(any("foobar/missing.md" in item for item in broken))
            self.assertTrue(any(
                "placeholder-data/missing.md" in item for item in broken))

    def test_fence_closer_requires_whitespace_after_marker(self):
        text = (
            "```sh\n"
            "npm run retained\n"
            "```suffix\n"
            "make retained\n"
            "```\n"
            "[Outside](missing.md)\n")

        self.assertEqual(
            [line for _, line in DOCS_DRIFT.fenced_blocks(text)],
            ["npm run retained", "```suffix", "make retained"])
        self.assertEqual(
            [line for _, line in DOCS_DRIFT.markdown_lines_without_code(text)],
            ["", "", "", "", "", "[Outside](missing.md)"])

    def test_make_inventory_incompleteness_suppresses_negative_checks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "Makefile").write_text(
                "%.o: %.c\n\t@echo pattern\n", encoding="utf-8")
            (repo / "README.md").write_text(
                "```sh\nmake generated\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

            (repo / "Makefile").write_text(
                "include generated-rules.mk\n", encoding="utf-8")
            result = DOCS_DRIFT.build(repo, ["Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_dynamic_cd_skips_npm_and_make_until_known_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            web = repo / "packages" / "web"
            web.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"root-only": "root"}}\n', encoding="utf-8")
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            (web / "package.json").write_text(
                '{"scripts": {"web-only": "web"}}\n', encoding="utf-8")
            (web / "Makefile").write_text("web-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                'cd "$WORK_DIR"\n'
                "npm run unknown\n"
                "make unknown\n"
                "cd packages/web\n"
                "npm run web-only\n"
                "make web-only\n"
                f'cd "{web.as_posix()}"\n'
                "npm run web-only\n"
                "make web-only\n"
                "npm run unknown\n"
                "make unknown\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "Makefile", "packages/web/package.json",
                "packages/web/Makefile", "README.md",
            ])
            kinds = [finding["kind"] for finding in result["findings"]]

            self.assertEqual(kinds.count("missing-script"), 1)
            self.assertEqual(kinds.count("missing-make-target"), 1)

    def test_quoted_cd_path_with_separator_is_tracked(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools;cache"
            script = tools / "scripts" / "existing.py"
            script.parent.mkdir(parents=True)
            script.write_text("print('ok')\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                '```sh\ncd "tools;cache" && python scripts/existing.py\n```\n',
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["tools;cache/scripts/existing.py", "README.md"])

            self.assertNotIn(
                "missing-script-file",
                {finding["kind"] for finding in result["findings"]})

    def test_script_paths_allow_quoted_interpreter_operands(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            scripts = repo / "scripts"
            scripts.mkdir()
            (scripts / "existing.py").write_text("print('ok')\n", encoding="utf-8")
            (scripts / "existing.ps1").write_text("Write-Output ok\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                'python "scripts/existing.py"\n'
                'pwsh -File "scripts/existing.ps1"\n'
                'python "scripts/missing.py"\n'
                'pwsh -File "scripts/missing.ps1"\n'
                'echo "python scripts/not-a-command.py"\n'
                'echo "pwsh -File scripts/not-a-command.ps1"\n'
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "scripts/existing.py", "scripts/existing.ps1", "README.md",
            ])

            missing = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script-file"
            ]
            self.assertEqual(len(missing), 2)

    def test_unresolved_pushd_keeps_prior_directories_for_popd(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "tools").mkdir()

            cwd, stack, _, _ = DOCS_DRIFT.script_commands_in_line(
                repo, "pushd tools", Path("."), [], False)
            cwd, stack, _, _ = DOCS_DRIFT.script_commands_in_line(
                repo, "pushd $WORK_DIR", cwd, stack, True)
            self.assertIsNone(cwd)
            self.assertEqual(stack, [Path("."), Path("tools")])

            cwd, stack, _, _ = DOCS_DRIFT.script_commands_in_line(
                repo, "popd", cwd, stack, True)
            self.assertEqual(cwd, Path("tools"))
            cwd, stack, _, _ = DOCS_DRIFT.script_commands_in_line(
                repo, "popd", cwd, stack, True)
            self.assertEqual(cwd, Path("."))
            self.assertEqual(stack, [])

    def test_script_path_restores_nested_pushd_directories(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            for relative in (
                    "tools/scripts/outer.py",
                    "tools/nested/scripts/inner.py",
                    "scripts/root.py"):
                script = repo / relative
                script.parent.mkdir(parents=True, exist_ok=True)
                script.write_text("print('ok')\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "pushd tools\n"
                "pushd nested\n"
                "python scripts/inner.py\n"
                "popd\n"
                "python scripts/outer.py\n"
                "popd\n"
                "python scripts/root.py\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "tools/scripts/outer.py", "tools/nested/scripts/inner.py",
                "scripts/root.py", "README.md",
            ])

            self.assertNotIn(
                "missing-script-file",
                {finding["kind"] for finding in result["findings"]})

    def test_unresolved_pushd_skips_script_path_resolution(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools"
            tools.mkdir()
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "pushd tools\n"
                "pushd $WORK_DIR\n"
                "python scripts/build.py\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["README.md"])

            self.assertNotIn(
                "missing-script-file",
                {finding["kind"] for finding in result["findings"]})

    def test_popd_with_empty_stack_keeps_current_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools"
            tools.mkdir()
            cwd, stack, _, commands = DOCS_DRIFT.script_commands_in_line(
                repo, "popd", Path("tools"), [], True)

            self.assertEqual(cwd, Path("tools"))
            self.assertEqual(stack, [])
            self.assertEqual(commands, [])

    def test_root_script_does_not_mask_missing_script_after_cd(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "tools").mkdir()
            root_script = repo / "scripts" / "build.py"
            root_script.parent.mkdir()
            root_script.write_text("print('root only')\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\ncd tools\npython scripts/build.py\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["scripts/build.py", "README.md"])

            missing = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script-file"
            ]
            self.assertEqual(len(missing), 1)

    def test_list_files_preserves_filename_whitespace_and_bytes(self):
        with patch.object(DOCS_DRIFT.shutil, "which", return_value="git"), \
                patch.object(DOCS_DRIFT.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = b" spaced name.md\0control\tname.md\0"
            self.assertEqual(
                DOCS_DRIFT.list_files(Path(".")),
                [" spaced name.md", "control\tname.md"])
            self.assertIn("-z", run.call_args.args[0])

    def test_from_import_marks_submodule_as_referenced(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            package = repo / "package"
            package.mkdir()
            (repo / "app.py").write_text("from package import config\n", encoding="utf-8")
            (package / "config.py").write_text(
                "import os\nAPI_TOKEN = os.getenv('API_TOKEN')\n", encoding="utf-8")
            dead = DOCS_DRIFT.unreferenced_modules(
                repo, ["app.py", "package/config.py"])
            self.assertNotIn("package/config.py", dead)

    def test_go_files_in_same_package_are_not_flagged_as_unreferenced(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "main.go").write_text(
                "package main\n\nfunc main() {\n\trunHelper()\n}\n",
                encoding="utf-8")
            (repo / "helper.go").write_text(
                'package main\n\nimport "os"\n\n'
                'func runHelper() {\n\t_ = os.Getenv("API_TOKEN")\n}\n',
                encoding="utf-8")
            (repo / "README.md").write_text(
                "Configure `API_TOKEN` before running the service.\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["main.go", "helper.go", "README.md"])

            self.assertNotIn(
                "documented-env-in-unreferenced-module",
                {finding["kind"] for finding in result["findings"]})

    def test_python_main_guarded_script_is_not_unreferenced(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            scripts = repo / "scripts"
            scripts.mkdir()
            (scripts / "load_token.py").write_text(
                "import os\n"
                "if __name__ == '__main__':\n"
                "    print(os.getenv('API_TOKEN'))\n",
                encoding="utf-8")
            (scripts / "helper.py").write_text("VALUE = 1\n", encoding="utf-8")
            (repo / "README.md").write_text(
                "Set `API_TOKEN` before running the standalone script.\n",
                encoding="utf-8")
            files = ["scripts/load_token.py", "scripts/helper.py", "README.md"]

            dead = DOCS_DRIFT.unreferenced_modules(repo, files)
            result = DOCS_DRIFT.build(repo, files)

            self.assertNotIn("scripts/load_token.py", dead)
            self.assertIn("scripts/helper.py", dead)
            self.assertNotIn(
                "documented-env-in-unreferenced-module",
                {finding["kind"] for finding in result["findings"]})

    def test_empty_npm_inventory_and_make_all_are_checked(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            docs = repo / "docs"
            docs.mkdir()
            (repo / "package.json").write_text(
                '{"scripts": {}}\n', encoding="utf-8")
            (repo / "Makefile").write_text("build:\n\t@echo build\n", encoding="utf-8")
            doc = docs / "commands.md"
            doc.write_text(
                "```sh\nnpm run build\nmake all\n```\n", encoding="utf-8")
            result = DOCS_DRIFT.build(
                repo, ["package.json", "Makefile", "docs/commands.md"])
            kinds = {finding["kind"] for finding in result["findings"]}
            self.assertIn("missing-script", kinds)
            self.assertIn("missing-make-target", kinds)

    def test_make_multi_target_rule_accepts_each_target_and_rejects_unknown(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "Makefile").write_text(
                "NAME := assignment\n"
                "build test: deps\n\t@echo $@\n", encoding="utf-8")
            self.assertEqual(
                DOCS_DRIFT.makefile_targets(repo, "Makefile"), {"build", "test"})
            doc = repo / "README.md"
            doc.write_text(
                "```sh\nmake build\nmake test\nmake unknown\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["Makefile", "README.md"])

            missing_targets = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-make-target"
            ]
            self.assertEqual(len(missing_targets), 1)
            self.assertIn("unknown", missing_targets[0]["detail"])

    def test_make_target_declared_only_in_nested_makefile_is_missing_at_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            nested = repo / "packages" / "web"
            nested.mkdir(parents=True)
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            (nested / "Makefile").write_text("web-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text("```sh\nmake web-only\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["Makefile", "packages/web/Makefile", "README.md"])

            missing_targets = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-make-target"
            ]
            self.assertEqual(len(missing_targets), 1)
            self.assertIn("web-only", missing_targets[0]["detail"])

    def test_make_uses_makefile_at_fenced_block_working_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            nested = repo / "packages" / "web"
            nested.mkdir(parents=True)
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            (nested / "Makefile").write_text("web-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\ncd packages/web\nmake web-only\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["Makefile", "packages/web/Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_make_pushd_popd_restores_root_makefile_for_later_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            nested = repo / "packages" / "web"
            nested.mkdir(parents=True)
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            (nested / "Makefile").write_text("web-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "pushd packages/web\n"
                "make web-only\n"
                "popd\n"
                "make root-only\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["Makefile", "packages/web/Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_dynamic_pushd_skips_npm_and_make_checks_until_restored(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            nested = repo / "packages" / "web"
            nested.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"root-only": "root"}}\n', encoding="utf-8")
            (nested / "package.json").write_text(
                '{"scripts": {"web-only": "web"}}\n', encoding="utf-8")
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            (nested / "Makefile").write_text("web-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "pushd packages/web\n"
                "pushd \"$WORK_DIR\"\n"
                "npm run unknown\n"
                "make unknown\n"
                "popd\n"
                "npm run web-only\n"
                "make web-only\n"
                "popd\n"
                "npm run root-only\n"
                "make root-only\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "packages/web/package.json", "Makefile",
                "packages/web/Makefile", "README.md",
            ])

            kinds = {finding["kind"] for finding in result["findings"]}
            self.assertNotIn("missing-script", kinds)
            self.assertNotIn("missing-make-target", kinds)

    def test_empty_root_makefile_is_an_inventory_for_unknown_targets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "Makefile").write_text("# no targets\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text("```sh\nmake surprise\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["Makefile", "README.md"])

            self.assertIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_make_target_is_not_checked_without_matching_makefile(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            nested = repo / "packages" / "web"
            nested.mkdir(parents=True)
            (nested / "Makefile").write_text("web-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text("```sh\nmake web-only\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["packages/web/Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_make_job_options_are_not_treated_as_targets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "Makefile").write_text("build:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "make -j4 build\n"
                "make -j 4 build\n"
                "make --jobs 4 build\n"
                "make --jobs=4 build\n"
                "```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_make_directory_and_file_options_select_nested_inventory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools"
            tools.mkdir()
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            (tools / "Makefile").write_text("deploy:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "make -C tools deploy\n"
                "make --directory=tools --file=Makefile deploy\n"
                "make -f tools/Makefile deploy\n"
                "make --file tools/Makefile deploy\n"
                "make root-only\n"
                "```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["Makefile", "tools/Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_make_option_operands_are_not_treated_as_targets(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools"
            tools.mkdir()
            (tools / "Makefile").write_text("deploy:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "make -j 4 -C tools -f Makefile deploy\n"
                "```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["tools/Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_unresolved_explicit_makefile_skips_target_validation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "Makefile").write_text("root-only:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "make -f --jobs=4 surprise\n"
                "make --file= missing-target\n"
                "make -f missing.mk unknown-target\n"
                "make --file=missing.mk unknown-target\n"
                "make missing-control\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["Makefile", "README.md"])

            missing_targets = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-make-target"
            ]
            self.assertEqual(len(missing_targets), 1)
            self.assertIn("missing-control", missing_targets[0]["detail"])

    def test_explicit_makefile_rejects_unknown_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools"
            tools.mkdir()
            (tools / "Makefile").write_text("deploy:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\nmake -f tools/Makefile surprise\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["tools/Makefile", "README.md"])

            missing_targets = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-make-target"
            ]
            self.assertEqual(len(missing_targets), 1)
            self.assertIn("surprise", missing_targets[0]["detail"])

    def test_explicit_makefile_accepts_known_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            tools = repo / "tools"
            tools.mkdir()
            (tools / "Makefile").write_text("deploy:\n", encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\nmake --file=tools/Makefile deploy\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["tools/Makefile", "README.md"])

            self.assertNotIn(
                "missing-make-target",
                {finding["kind"] for finding in result["findings"]})

    def test_npm_scripts_are_checked_for_invocation_working_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "packages" / "web").mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"test": "test"}}\n', encoding="utf-8")
            (repo / "packages" / "web" / "package.json").write_text(
                '{"scripts": {"build": "build"}}\n', encoding="utf-8")
            package_doc = repo / "packages" / "web" / "README.md"
            package_doc.write_text("```sh\nnpm run build\n```\n", encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text(
                """```sh
npm run test
```

```sh
cd packages/web
npm run build
```

```sh
npm --prefix packages/web run build
```

```sh
npm run build
```
""",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, [
                    "package.json",
                    "packages/web/package.json",
                    "packages/web/README.md",
                    "docs/commands.md",
                ])
            missing_scripts = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script"
            ]
            self.assertEqual(len(missing_scripts), 1)
            self.assertIn("build", missing_scripts[0]["detail"])
            self.assertEqual(missing_scripts[0]["line"], 15)

    def test_npm_workspace_path_selector_uses_workspace_scripts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            workspace = repo / "packages" / "web"
            workspace.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"root-only": "root"}}\n', encoding="utf-8")
            (workspace / "package.json").write_text(
                '{"name": "@acme/web", "scripts": {"build": "build"}}\n',
                encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text("```sh\nnpm -w web run build\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["package.json", "packages/web/package.json", "docs/commands.md"])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_npm_pushd_popd_restores_root_package_for_later_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            nested = repo / "packages" / "web"
            nested.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"root-only": "root"}}\n', encoding="utf-8")
            (nested / "package.json").write_text(
                '{"scripts": {"web-only": "web"}}\n', encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text(
                "```sh\n"
                "pushd packages/web\n"
                "npm run web-only\n"
                "popd\n"
                "npm run root-only\n"
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["package.json", "packages/web/package.json", "README.md"])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_npm_workspace_name_selector_uses_workspace_scripts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            workspace = repo / "packages" / "web"
            workspace.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"root-only": "root"}}\n', encoding="utf-8")
            (workspace / "package.json").write_text(
                '{"name": "@acme/web", "scripts": {"build": "build"}}\n',
                encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text(
                "```sh\nnpm --workspace @acme/web run build\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["package.json", "packages/web/package.json", "docs/commands.md"])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_npm_workspaces_checks_each_declared_workspace(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            web = repo / "packages" / "web"
            api = repo / "packages" / "api"
            web.mkdir(parents=True)
            api.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"workspaces": ["packages/*"], "scripts": {"root": "root"}}\n',
                encoding="utf-8")
            (web / "package.json").write_text(
                '{"scripts": {"build": "build"}}\n', encoding="utf-8")
            (api / "package.json").write_text(
                '{"scripts": {"test": "test"}}\n', encoding="utf-8")
            (repo / "README.md").write_text(
                "```sh\nnpm --workspaces run build\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "packages/web/package.json",
                "packages/api/package.json", "README.md",
            ])

            missing = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script"
            ]
            self.assertEqual(len(missing), 1)
            self.assertIn("every applicable package.json", missing[0]["detail"])

    def test_npm_workspaces_skips_only_when_workspace_selection_is_unknown(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "package.json").write_text(
                '{"scripts": {"build": "root"}}\n', encoding="utf-8")
            (repo / "README.md").write_text(
                "```sh\nnpm --workspaces run missing\n```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["package.json", "README.md"])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_shell_separators_inside_quotes_are_not_commands(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "package.json").write_text(
                '{"scripts": {"test": "test"}}\n', encoding="utf-8")
            (repo / "Makefile").write_text("build:\n", encoding="utf-8")
            (repo / "scripts").mkdir()
            (repo / "scripts" / "existing.py").write_text(
                "print('ok')\n", encoding="utf-8")
            (repo / "README.md").write_text(
                "```sh\n"
                'echo "example; make ghost"\n'
                'echo "npm run removed; pwsh scripts/retired.ps1"\n'
                "# npm run retired\n"
                "make build # make ghost\n"
                "# python scripts/retired.py\n"
                "python scripts/existing.py # python scripts/retired.py\n"
                'npm run test --message "literal; npm run removed"\n'
                "```\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "Makefile", "scripts/existing.py", "README.md",
            ])

            self.assertFalse(any(
                finding["kind"] in {
                    "missing-script", "missing-make-target", "missing-script-file"
                }
                for finding in result["findings"]))
            self.assertEqual(
                DOCS_DRIFT.strip_shell_comment('make "build # literal" # comment'),
                'make "build # literal" ')
            self.assertEqual(
                DOCS_DRIFT.strip_shell_comment("make build#literal"),
                "make build#literal")

    def test_npm_multi_workspace_flags_script_missing_from_one_workspace(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            web = repo / "packages" / "web"
            api = repo / "packages" / "api"
            web.mkdir(parents=True)
            api.mkdir(parents=True)
            (repo / "package.json").write_text('{}\n', encoding="utf-8")
            (web / "package.json").write_text(
                '{"name": "@acme/web", "scripts": {"build": "build"}}\n',
                encoding="utf-8")
            (api / "package.json").write_text(
                '{"name": "@acme/api", "scripts": {"test": "test"}}\n',
                encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text(
                "```sh\nnpm -w packages/web --workspace @acme/api run build\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "packages/web/package.json", "packages/api/package.json",
                "docs/commands.md",
            ])

            missing_scripts = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script"
            ]
            self.assertEqual(len(missing_scripts), 1)
            self.assertIn("build", missing_scripts[0]["detail"])
            self.assertIn("every applicable package.json", missing_scripts[0]["detail"])

    def test_npm_multi_workspace_if_present_allows_missing_script(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            web = repo / "packages" / "web"
            api = repo / "packages" / "api"
            web.mkdir(parents=True)
            api.mkdir(parents=True)
            (repo / "package.json").write_text('{}\n', encoding="utf-8")
            (web / "package.json").write_text(
                '{"name": "@acme/web", "scripts": {"build": "build"}}\n',
                encoding="utf-8")
            (api / "package.json").write_text(
                '{"name": "@acme/api", "scripts": {"test": "test"}}\n',
                encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text(
                "```sh\nnpm -w packages/web --workspace @acme/api run build --if-present\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "packages/web/package.json", "packages/api/package.json",
                "docs/commands.md",
            ])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_npm_single_selected_workspace_script_is_valid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            web = repo / "packages" / "web"
            api = repo / "packages" / "api"
            web.mkdir(parents=True)
            api.mkdir(parents=True)
            (repo / "package.json").write_text('{}\n', encoding="utf-8")
            (web / "package.json").write_text(
                '{"name": "@acme/web", "scripts": {"build": "build"}}\n',
                encoding="utf-8")
            (api / "package.json").write_text(
                '{"name": "@acme/api", "scripts": {"test": "test"}}\n',
                encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text(
                "```sh\nnpm --workspace @acme/web run build\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(repo, [
                "package.json", "packages/web/package.json", "packages/api/package.json",
                "docs/commands.md",
            ])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_unresolved_npm_workspace_selector_skips_script_check(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            workspace = repo / "packages" / "web"
            workspace.mkdir(parents=True)
            (repo / "package.json").write_text(
                '{"scripts": {"root-only": "root"}}\n', encoding="utf-8")
            (workspace / "package.json").write_text(
                '{"name": "@acme/web", "scripts": {"build": "build"}}\n',
                encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            doc = docs / "commands.md"
            doc.write_text(
                "```sh\nnpm --workspace missing run build\n```\n",
                encoding="utf-8")

            result = DOCS_DRIFT.build(
                repo, ["package.json", "packages/web/package.json", "docs/commands.md"])

            self.assertNotIn(
                "missing-script",
                {finding["kind"] for finding in result["findings"]})

    def test_npm_run_parser_handles_script_boundaries_and_quoted_prefixes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            npm = {
                ".": {"cli", "migrate"},
                "packages/web": {"build", "web-marker"},
                "packages/web app": {"build", "space-marker"},
                "run": {"cli", "prefix-marker"},
            }
            cases = [
                ("npm run cli -- run migrate", "cli", {"cli", "migrate"}),
                ("npm --prefix run run cli", "cli", {"cli", "prefix-marker"}),
                ("npm --loglevel info run build", "build",
                 {"cli", "migrate"}),
                ('npm --prefix "packages/web" run build', "build",
                 {"build", "web-marker"}),
                ("npm run build --prefix packages/web", "build",
                 {"build", "web-marker"}),
                ('npm run build --prefix "packages/web app"', "build",
                 {"build", "space-marker"}),
                (r'npm --prefix "packages\web app" run build', "build",
                 {"build", "space-marker"}),
                ('npm --prefix "packages/web" run build --prefix "packages/web app"',
                 "build", {"build", "space-marker"}),
                ('npm --prefix "packages/web app" run build -- --prefix packages/web',
                 "build", {"build", "space-marker"}),
            ]
            for command, expected_script, expected_scripts in cases:
                with self.subTest(command=command):
                    _, calls = DOCS_DRIFT.npm_commands_in_line(
                        repo, npm, command, Path("."))
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(calls[0], (expected_script, [expected_scripts], False))

    def test_tilde_fenced_commands_are_checked(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir)
            (repo / "package.json").write_text(
                '{"scripts": {"test": "test"}}\n', encoding="utf-8")
            doc = repo / "README.md"
            doc.write_text("~~~sh\nnpm run build\n~~~\n", encoding="utf-8")

            result = DOCS_DRIFT.build(repo, ["package.json", "README.md"])
            missing_scripts = [
                finding for finding in result["findings"]
                if finding["kind"] == "missing-script"
            ]
            self.assertEqual(len(missing_scripts), 1)
            self.assertIn("build", missing_scripts[0]["detail"])
            self.assertEqual(missing_scripts[0]["line"], 2)


if __name__ == "__main__":
    unittest.main()
