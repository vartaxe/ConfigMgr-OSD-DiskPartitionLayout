# Compatibility and profile matrix

This project is a fresh-install partitioning engine for ConfigMgr WinPE. It
does not claim that every firmware, storage controller, operating system, or
OEM image is interchangeable. The exact boot image, storage drivers, firmware
settings and OS image must be tested together.

## Supported layout profiles

| Profile | Invocation | Layout | Intended use | Status |
| --- | --- | --- | --- | --- |
| Modern UEFI | `-RequireUEFI` | GPT: EFI, MSR, Windows, Recovery | Windows 10/11 and current UEFI deployments | Supported baseline; field validation required |
| Automatic dual-mode | no firmware requirement | GPT in UEFI, MBR in BIOS | A task sequence that genuinely supports both modes | Supported baseline; image compatibility is the administrator's responsibility |
| Legacy BIOS | `-RequireBIOS` | MBR: active System, Windows, Recovery | Legacy BIOS/CSM and older OS images | Supported baseline on 512-byte-sector disks up to 2 TB |
| Fixed Windows plus Data | `-WindowsSizeGiB N -CreateDataPartition` | Standard layout plus a final NTFS Data partition | OEM, kiosk, lab and split-OS/data profiles | Supported with four-primary-partition and MBR2GPT caveats |
| Approved virtual machine | `-AllowVirtualDisk -TargetBusType Virtual` | Firmware-appropriate standard layout | Lab and virtual-machine deployment | Explicit opt-in; validate the hypervisor |
| Surface Storage Spaces | `-AllowSurfaceStorageSpaces ...` | Firmware-appropriate layout on the verified virtual disk | Affected Surface 1-TB configurations | Explicit opt-in; hardware validation required |

The standard profile is deliberately conservative. It supports custom target
selection and sizing, but not arbitrary partition types, arbitrary filesystem
commands, or caller-supplied DiskPart text. A custom deployment should use a
new, versioned profile with its own planner, postconditions and tests rather
than bypassing the safety checks.

## Storage and firmware coverage

| Environment | Default policy | Required validation |
| --- | --- | --- |
| NVMe, SATA or ATA internal disk | Eligible when healthy and uniquely selected | Confirm the disk is visible in the exact WinPE image |
| Intel VMD/RST/RAID | No universal driver assumption | Inject the OEM-approved WinPE storage driver and test the firmware storage mode |
| SAS/SCSI | Explicit target rule required | Prove that attached storage cannot be selected accidentally |
| USB, SD/MMC or removable media | Rejected | Do not override this with a generic bus rule |
| USB4/Thunderbolt NVMe enclosure | Bus type may be misleading | Use a tested positive identity rule; never rely on bus type alone |
| 4Kn disk | UEFI/GPT only | Test WinPE, DiskPart, image application, WinRE and BitLocker |
| BIOS/MBR | 512n/512e and no more than 2 TB decimal | Test active System, boot files, image application and first boot |
| UEFI/GPT | Current recommended path | Test Secure Boot, TPM, WinRE and OS-image architecture |
| Storage Spaces, VROC or hardware RAID | Not selected automatically | Treat the exposed virtual disk and its driver mapping as a separate hardware profile |

If the intended disk is absent from WinPE, stop and fix the boot image or
firmware storage configuration. A disk-selection script cannot safely select a
device that the operating system does not enumerate.

## Operating-system generations

- **Current Windows 11:** use UEFI boot, GPT and `-RequireUEFI`. Validate TPM,
  Secure Boot capability, supported CPU, image architecture, ADK/ConfigMgr
  support and storage drivers separately.
- **Windows 10 and other current UEFI-capable images:** use the Modern UEFI
  profile unless the image and hardware policy intentionally permits BIOS.
- **Older BIOS-based Windows images:** use `-RequireBIOS` and the MBR profile.
  The disk must satisfy the 512-byte-sector and 2-TB checks.
- **Older UEFI images:** test the image's boot files and WinPE pairing. A GPT
  layout alone does not prove that an older image can boot on the target.
- **Existing installations and BIOS-to-UEFI conversion:** do not use this
  destructive fresh-install script. Use a separate MBR2GPT workflow with
  BitLocker, partition-count, BCD and firmware-transition validation.
- **WinRE repair or resizing:** use a separate repair workflow. This script
  creates a correctly typed partition but does not populate or register
  `winre.wim`.

Older x86 WinPE and older ConfigMgr sites may work when PowerShell 5.1,
Storage WMI, ConfigMgr task-sequence COM support, DiskPart and the required
storage drivers are present, but they are not certified by this project.
PowerShell 2/3/4 is outside the current compatibility boundary because the
script requires Windows PowerShell 5.1.

## Custom configuration contract

The following are safe customizations of the standard profile:

- target serial, disk model, computer model and bus filters;
- minimum and maximum disk-size policy;
- EFI, BIOS System, Recovery and Windows partition sizes;
- optional fixed-size NTFS Data partition;
- task-sequence variable names for the selected disk and Windows partition;
- explicit UEFI-only, BIOS-only or dual-mode policy.

The following require a separate profile and must not be emulated by editing
the generated command file:

- arbitrary partition counts or order;
- custom GPT/MBR type identifiers;
- dynamic disks, extended/logical MBR partitions or Storage Spaces pool
  members;
- non-NTFS Windows/Recovery/Data filesystems;
- repartitioning an existing installation;
- automatic drive-letter policy beyond the temporary `W:`/`S:` hand-off.

Every future profile should provide:

1. a documented parameter contract;
2. a pure planning function;
3. fail-closed target and firmware checks;
4. generated commands with no raw command injection;
5. post-DiskPart type, size, order, identity and filesystem checks;
6. synthetic tests plus disposable-hardware validation evidence.

## OEM validation set

Before calling a profile production-ready, test at least one representative
device and the exact boot image for each deployed family:

- Dell Command Configure/driver-pack-managed systems;
- Lenovo SCCM/MDT driver-pack systems;
- HP Image Assistant/SoftPaq-managed systems;
- Microsoft Surface, including affected Storage Spaces models;
- Intel NUC and current Intel VMD/RST platforms;
- ASUS or other OEM systems used by the organization.

Record firmware mode, Secure Boot state, TPM state, storage mode, logical
sector size, visible disks, selected disk identity, partition postconditions,
Apply Operating System behavior, first boot and `reagentc /info`. After adding
WinPE drivers or optional components, update and redistribute the boot image
and recreate affected media before retesting.

