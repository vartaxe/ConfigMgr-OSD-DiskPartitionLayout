<p align="center">
  <picture>
    <source media="(max-width: 720px)" srcset="assets/banner-compact.svg?v=1.0.0" width="640">
    <img src="assets/banner.svg?v=1.0.0" alt="ConfigMgr OSD Disk Partition Layout; Invoke-OSDDiskLayout.ps1; Windows PowerShell 5.1." width="1280" height="320">
  </picture>
</p>

# ConfigMgr OSD Disk Partition Layout

Select one approved target disk and create a firmware-appropriate GPT or MBR layout in one Configuration Manager WinPE task-sequence step.

**Current version: 1.0.0.** This README follows `main`; published releases are versioned snapshots.

[Quick start](#quick-start) | [Task-sequence integration](TASK-SEQUENCE.md) | [Compatibility](docs/COMPATIBILITY-MATRIX.md) | [Contributing](CONTRIBUTING.md) | [Security](SECURITY.md)

[![Release v1.0.0](https://img.shields.io/badge/RELEASE-v1.0.0-155799)](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/releases/tag/v1.0.0)
[![CI - main push](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/actions/workflows/ci.yml?query=branch%3Amain+event%3Apush)
![Windows PowerShell 5.1](https://img.shields.io/badge/Windows%20PowerShell-5.1-155799)
[![MIT license](https://img.shields.io/badge/license-MIT-117865)](LICENSE)

## Safety first

**In an active WinPE task sequence, running with no parameters irreversibly cleans and repartitions the selected disk.** `clean` removes partition metadata; it is not secure erasure. Use only for a fresh install, test with disposable disks, and validate the exact ConfigMgr boot image and hardware before rollout.

The script fails closed when no unique target is approved, firmware checks conflict, disk identity changes, task-sequence content may be on the target, or post-format verification fails. A missing WinPE storage driver can hide the intended disk, so automatic single-disk selection is inappropriate on known multi-drive hardware. For Windows 11-only sequences, pass `-RequireUEFI`; BIOS/MBR is only suitable for compatible legacy-boot operating systems.

**Version 1.0.0 is not field-certified.** Automated tests and a passing CI run do not replace disposable-hardware validation in your own task sequence.

## Requirements

- An active ConfigMgr task sequence in WinPE using Windows PowerShell 5.1.
- WinPE PowerShell, WMI, Storage WMI, `wpeutil.exe`, DiskPart, ConfigMgr task-sequence COM access, and the required storage-controller drivers.
- An OS image compatible with the detected firmware mode. `-RequireUEFI` checks boot mode only; it does not validate Windows 11 hardware requirements.
- Task-sequence content, working files, logs, and WinPE itself located off the selected target disk.

See the [compatibility matrix](docs/COMPATIBILITY-MATRIX.md) for explicit firmware, storage, and OS support boundaries.

## Quick start

1. Start with a copy of the task sequence and disposable test media. Review the [integration guide](TASK-SEQUENCE.md) before adding the script.
2. Package `Scripts/Invoke-OSDDiskLayout.ps1` and add one **Run PowerShell Script** step in WinPE before **Apply Operating System**. Do not leave another Format and Partition Disk step active on the same path.
3. For a Windows 11-only image, set **Parameters** to `-RequireUEFI`. Use no parameters only for a fleet known to have one internal OS disk and validated WinPE storage drivers.
4. Set Apply Operating System to use the `OSPART` task-sequence variable. Gate it on the layout success variables, and leave **Continue on error** unchecked.
5. Run `-Preview` first in the exact WinPE environment, then validate destructive behavior only on a disposable disk. After installation, verify boot and WinRE with `reagentc /info`.

For multi-disk systems, use a tested unique rule such as `-TargetSerial` or a cumulative disk-bus and disk-model rule. Disk model filters apply to the disk, not the computer; ambiguous results stop without formatting.

## Default layouts

| Firmware | Partition order | Hand-off |
|---|---|---|
| UEFI | GPT: EFI, MSR, Windows, Recovery | `OSPART=W:`; EFI 1024 MiB, MSR 16 MiB, Recovery 2048 MiB by default |
| BIOS | MBR: active System, Windows, Recovery | `OSPART=W:`; System 512 MiB, Recovery 2048 MiB by default |

An optional fixed-size Windows plus Data profile is available with `-WindowsSizeGiB N -CreateDataPartition`. The script creates a correctly typed Recovery partition but does not apply Windows, register WinRE, configure Secure Boot/TPM, or assign a permanent Data drive letter. See the [task-sequence guide](TASK-SEQUENCE.md) for output variables, step settings, and rollout checks.

## Validation and rollout

The repository validation runs Windows PowerShell 5.1 parsing, PSScriptAnalyzer, Pester tests, root/package byte-parity checks, and complete `CHECKSUMS.txt` verification. The tests exercise pure selection/planning/postcondition logic and static entry-point safety checks without cleaning disks; they do not prove that a real ConfigMgr/WinPE deployment succeeds.

**Live ConfigMgr, WinPE, firmware, storage-driver, OS-image, and disposable-disk validation has not been completed for this release.** Use the [compatibility matrix](docs/COMPATIBILITY-MATRIX.md) to plan a controlled pilot. Check [CI](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/actions/workflows/ci.yml) for the status of a specific revision.

## Source and release files

The repository is authoritative. The [v1.0.0 release](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout/releases/tag/v1.0.0) includes a versioned source ZIP and SHA-256 sidecar. Verify the archive before extraction. The validation script also checks that `Scripts/Invoke-OSDDiskLayout.ps1` remains byte-identical to the root source copy. Existing ConfigMgr packages do not update automatically.

## Maintainer

**Claudio Mendes** · [@vartaxe](https://github.com/vartaxe) · [vartaxe@outlook.com](mailto:vartaxe@outlook.com)

## Related projects

- [Copy OSD Logs to File Share](https://github.com/vartaxe/ConfigMgr-OSD-CopyOSDLogToFileShare) - companion task-sequence diagnostics utility ([documentation](https://vartaxe.github.io/ConfigMgr-OSD-CopyOSDLogToFileShare/)).
- [Add Computer to AD Group](https://github.com/vartaxe/ConfigMgr-OSD-AddComputerToADGroup) - post-domain-join group membership utility ([documentation](https://vartaxe.github.io/ConfigMgr-OSD-AddComputerToADGroup/)).

## License

MIT. See [LICENSE](LICENSE).
