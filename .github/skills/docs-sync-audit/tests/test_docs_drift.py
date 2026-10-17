import importlib.util
import tempfile
import unittest
from pathlib import Path

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
[Fake](not-a-real-link.md)
```

PowerShell cast: `[Security.Principal.WindowsIdentity]::GetCurrent(`.

[Real broken link](missing.md)
""",
                encoding="utf-8")
            assets = repo / "assets"
            assets.mkdir()
            (assets / "file with spaces.md").write_text("# Valid target\n", encoding="utf-8")
            docs = repo / "docs"
            docs.mkdir()
            encoded_link_doc = docs / "links.md"
            encoded_link_doc.write_text("[Encoded link](../assets/file%20with%20spaces.md)\n", encoding="utf-8")
            files = [
                ".github/skills/copilot-pr-autopilot/SKILL.md",
                ".github/skills/copilot-pr-autopilot/references/01-request-review.md",
                ".github/skills/copilot-pr-autopilot/scripts/02-check-review-status.ps1",
                "assets/file with spaces.md",
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


if __name__ == "__main__":
    unittest.main()
