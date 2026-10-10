# Repository guidance

## Architecture and compatibility

- Treat the live working tree as authoritative and inspect related scripts,
  tests, documentation, and generated artifacts before editing.
- Keep `Invoke-OSDDiskLayout.ps1` and
  `Scripts/Invoke-OSDDiskLayout.ps1` byte-identical and compatible with Windows
  PowerShell 5.1 in ConfigMgr WinPE.
- Preserve existing public parameters, task-sequence variables, preview
  behavior, exit behavior, and fail-closed target selection unless the
  requested change explicitly changes a documented contract.
- Keep script version metadata, release notes, documentation, and release
  workflow expectations consistent.

## Safety and reliability

- Disk layout execution is destructive. Never weaken target identity,
  firmware, storage, task-sequence-content, or postcondition guards.
- Keep hardware-writing behavior out of automated tests; use synthetic inputs
  and clearly state any untested live hardware boundary.
- Never include disk serials, credentials, internal paths, or unredacted logs
  in code, tests, documentation, or issue examples.

## Validation

- Run `build/Invoke-Validation.ps1` with Windows PowerShell 5.1.
- Use Pester 6.2.0 and keep all tests fully passing with no skipped or not-run
  cases.
- Regenerate `CHECKSUMS.txt` after maintained files change; do not bypass its
  final verification for completion.
- Verify the root and packaged scripts remain byte-identical.
