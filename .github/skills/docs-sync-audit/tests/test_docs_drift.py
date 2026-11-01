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
            self.assertNotIn("Fake", " ".join(broken_links))

            env_names = DOCS_DRIFT.env_names_from_code(repo, files)
            self.assertEqual(set(env_names), {"WINDIR", "SYSTEMDRIVE", "COMPUTERNAME"})

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


if __name__ == "__main__":
    unittest.main()
