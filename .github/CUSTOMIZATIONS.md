# Repository Copilot customizations

The reusable bundle was promoted from DriverAutomationTool and originally
installed from [github/awesome-copilot](https://github.com/github/awesome-copilot)
at commit `82701c24b99488536ca399ff4789a458b7a05db7`. Its MIT license is
retained in [AWESOME-COPILOT-LICENSE](AWESOME-COPILOT-LICENSE).

| Customization | Location | Purpose |
|---|---|---|
| Repository guidance | [Copilot instructions](copilot-instructions.md) | Project architecture, safety boundaries, and validation contract |
| Terminal helper | [Agent profile](agents/terminal-helper.agent.md) | PowerShell and Bash command assistance |
| Microsoft Learn contributor | [Agent profile](agents/microsoft_learn_contributor.agent.md) | Documentation structure, accessibility, and Microsoft writing style |
| PowerShell guidance | [Instructions](instructions/powershell.instructions.md) | Applies to `*.ps1` and `*.psm1` |
| Pester 6 guidance | [Instructions](instructions/powershell-pester-6.instructions.md) | Applies to `*.Tests.ps1` |
| Copilot PR autopilot | [Skill](skills/copilot-pr-autopilot/SKILL.md) | Explicitly requested PR review and feedback loops |

The imported bundle contains 29 files. Its seven PowerShell scripts retain the
UTF-8 byte-order mark required for reliable Windows PowerShell 5.1 parsing.
Installing these files does not start an agent, execute a skill, or change the
application. Preserve Windows PowerShell 5.1 compatibility and existing public
contracts when applying general guidance.

The PR skill requires an explicitly selected pull request, authenticated GitHub
CLI, and the permissions documented in the skill. It can commit, push, reply,
and resolve review threads when invoked; installation performs none of those
operations.
