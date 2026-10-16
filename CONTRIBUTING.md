# Contributing

Contributions that improve safety, compatibility, tests, or documentation are welcome.

## Before opening an issue

- Use [private vulnerability reporting](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/security/advisories/new) for security concerns.
- Do not publish disk serials, task-sequence logs, credentials, or internal deployment details.
- Search existing issues and include the exact ConfigMgr, WinPE, firmware, storage-controller, and disk context needed to reproduce the behavior.

## Pull requests

1. Create a focused branch from `main`.
2. Keep the root and `Scripts/Invoke-OSDDiskLayout.ps1` copies byte-identical.
3. Preserve the fail-closed safety model. A change must not guess a target disk, weaken identity rechecks, or move a destructive operation ahead of its guards.
4. Add synthetic tests for changed selection, planning, command, or postcondition logic. Tests must not clean or repartition hardware.
5. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Invoke-Validation.ps1`.
6. Update user-facing documentation when support boundaries, parameters, task-sequence integration, or release behavior change.

Pull requests should describe the risk addressed, the validation performed, and any remaining hardware-validation boundary. Automated tests do not establish field certification; test destructive behavior only on disposable disks in a controlled ConfigMgr/WinPE pilot.

Regenerate `CHECKSUMS.txt` after all maintained-file changes and before final validation. The manifest hashes checked-out bytes after the repository `.gitattributes` rules are applied: PowerShell files use CRLF and other maintained text uses LF.

## Bounded cleanup

`New-OSDDiskPartCommands` collects its ordered command strings in one array
expression instead of repeatedly reallocating the array with `+=`. The root and
package copies remain byte-identical and self-contained. Synthetic regression
tests check every command for UEFI and BIOS, with and without Data, and ensure
unknown firmware returns no partial command list. Selection, safety checks,
parameters, error messages, exit codes, and DiskPart execution are unchanged.
These tests generate strings only; they do not validate hardware or a live task sequence.
