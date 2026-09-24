# ConfigMgr OSD: dynamic UEFI/GPT and BIOS/MBR disk layout

**Status: 1.0.0. Not validated in a live ConfigMgr/WinPE task sequence.**
Do not publish it as production-ready until the validation matrix below passes
on disposable disks and the actual boot images used by your fleet.

`Invoke-OSDDiskLayout.ps1` performs disk selection and partitioning in
**one Run PowerShell Script task-sequence step**; it replaces, not supplements,
ConfigMgr **Format and Partition Disk**. **In an active WinPE task sequence,
NO PARAMETERS irreversibly erase the only eligible internal disk.** The
*actual WinPE boot mode* selects UEFI/GPT or legacy BIOS/MBR automatically.
An internal disk can be Disk 0, 2 or 3; disk numbers need not be consecutive.
If no unique safe target is found, it stops before the destructive command.
Outside an active task sequence, no-parameter execution refuses to proceed;
use `-Preview` for a no-disk-write inventory and plan.
For the recommended **task-sequence structure, step settings and variable
conditions**, see [TASK-SEQUENCE.md](TASK-SEQUENCE.md). For the supported
legacy, modern, OEM and custom-profile boundaries, see
[docs/COMPATIBILITY-MATRIX.md](docs/COMPATIBILITY-MATRIX.md).

**Breaking change from 0.4.1-preview:** BIOS boot now triggers a destructive
MBR layout instead of being rejected. In a Windows 11-only task sequence,
use `-RequireUEFI` to stop **before** cleaning a BIOS-booted disk. Check the
image and firmware policy before upgrading an existing task sequence. The
earlier 0.3.0-preview also required `-Apply`; that switch no longer exists.
**0.5.1-preview safety change:** an otherwise eligible disk is now blocked
when the running script or task-sequence working/log files appear to reside
on it. Run a WinPE `-Preview` before swapping the earlier package.

**1.0.0 stable release:** the reviewed 0.5.1 RC is promoted without changing
the safety contract or layout behavior. The release remains subject to the
live validation requirements documented below; stable versioning does not
replace hardware and task-sequence acceptance testing.

## Layout and hand-off

| UEFI/GPT order | Partition | Size | Filesystem / type |
| --- | --- | --- | --- |
| 1 | EFI System | 1024 MiB by default | FAT32, EFI system GUID |
| 2 | Microsoft Reserved | 16 MiB | MSR GUID, unformatted |
| 3 | Windows | Disk-dependent, leaving room for Recovery and alignment | NTFS, temporary letter `W:` |
| 4 | Windows Recovery | 2048 MiB by default | NTFS, Recovery GUID, GPT attributes `0x8000000000000001` |
| 5 (optional) | Data | Remaining capacity after a fixed-size Windows partition | NTFS, no assigned letter |

| BIOS/MBR order | Partition | Size | Filesystem / type |
| --- | --- | --- | --- |
| 1 | System Reserved | 512 MiB by default | NTFS, active, temporary letter `S:` |
| 2 | Windows | Disk-dependent, leaving room for Recovery and alignment | NTFS, temporary letter `W:` |
| 3 | Windows Recovery | 2048 MiB by default | NTFS, MBR type `0x27`, no letter requested by the script |
| 4 (optional) | Data | Remaining capacity after a fixed-size Windows partition | NTFS, no assigned letter |

The Recovery partition is **immediately after Windows** and is the final
partition in the default layout; optional Data comes **after** Recovery.
A small unallocated tail remains: the script reserves 32 MiB
from the reported total for alignment/metadata. It checks the actual
partition style, count, types, sizes, order, Windows/Recovery adjacency,
Windows/System filesystems and WinPE drive letters before reporting success.
Recovery NTFS is also checked when WinPE exposes the hidden volume. On GPT it
checks Recovery's no-default-letter flag. DiskPart sets the GPT required
attribute, but `Get-Partition` does not expose it; inspect that raw attribute
in field validation. On MBR it checks that System is active and Recovery
has type 39 (`0x27`); the GPT-only no-default-letter property is **not**
used as an MBR postcondition.
Windows PE can temporarily mount an MBR Recovery volume despite its type;
verify that it is hidden after reboot. The script never explicitly assigns
Recovery a letter.

Successful output variables:

- `OSPART=W:` by default: configure **Apply Operating System** to use
  **Logical drive letter stored in a variable** and enter `OSPART` (without
  percent signs). The name can be changed with `-OSPartitionVariable`; use
  the same name in Apply Operating System.
- `OSDDiskIndex=<selected number>` by default: diagnostics / later steps,
  not the image destination for this custom partitioning step. Change its
  name with `-DiskNumberVariable` if needed.
- `DiskLayoutStatus=Success`, `DiskSelectionStatus=Success`,
  `DiskLayoutMode=FreshInstall`, and `DiskPartitionStyle=GPT` or `MBR`.
- `DiskDataPartitionGuid=<guid>` only when a GPT optional Data profile
  succeeds; it is cleared for MBR and for layouts without Data. A later
  full-Windows step can use this GUID for GPT Data. On MBR, identify the
  selected disk and fourth partition after boot; MBR has no GPT partition
  GUID. Neither profile promises that Data will become `D:` automatically.

The script clears these outputs at the start and on failure. It never sets
success if DiskPart or the post-format checks fail. Storage inventory may
refresh slowly after DiskPart; it retries **read-only** verification up to
three times, but never retries `clean` or formatting automatically.
Before clean, it also rechecks that the selected disk is still healthy,
writable and identified by the same disk and device properties. Administrator
model regexes have a one-second match timeout; invalid or runaway expressions
stop the step rather than delaying it indefinitely.
It also maps the running script, `_SMSTSMDataPath` working data and
`_SMSTSLogPath` to physical disks. If any is on the selected disk—or a
local mapping cannot be verified—it refuses to wipe possible task-sequence
content. This is a **stop condition**, not an automatic migration of the
task sequence's package/cache.

## Requirements and compatibility boundary

The engine is intentionally profile-driven: the standard profile covers
modern UEFI/GPT, legacy BIOS/MBR, explicit target rules, configurable sizes,
optional Data storage, approved virtual machines and the documented Surface
Storage Spaces exception. It supports broad hardware variation without
guessing. It does not accept arbitrary DiskPart text or unrestricted custom
partition definitions; those need a separately versioned planner and
postcondition suite. See
[docs/COMPATIBILITY-MATRIX.md](docs/COMPATIBILITY-MATRIX.md) before adding a
new OEM or legacy profile.

- An **active WinPE ConfigMgr task sequence**, with Windows PowerShell **5.1**,
  WMI, Storage WMI, `wpeutil.exe` and DiskPart available. Verify the WinPE
  PowerShell, NetFX, Scripting, WMI and StorageWMI optional components and
  the actual storage-controller drivers in each boot image. The script
  compares `PEFirmwareType` from `wpeutil UpdateBootInfo` (1=BIOS, 2=UEFI)
  with ConfigMgr's `_SMSTSBootUEFI` when that variable is populated.
  Unknown or contradictory values stop before `clean`.
- An OS image and subsequent **Apply Operating System** step. This script
  creates partitions, but does not deploy the image, register WinRE, or
  configure Secure Boot/TPM.
- The `Microsoft.SMS.TSEnvironment` COM object must be accessible in the
  task-sequence step. Destructive execution fails closed if it is not.
- `W:` must be free or belong to the selected disk. BIOS mode also needs `S:`.
- BIOS mode requires **512-byte logical sectors** (512n or 512e, not 4Kn)
  and a disk no larger than **2 TB decimal**. Both are checked before clean.
  UEFI/GPT is the path for supported 4Kn disks and larger capacities.
- BIOS/MBR does **not** make Windows 11 compatible with legacy boot. For
  Windows 11-only deployments, use `-RequireUEFI` and gate your image on
  compatible firmware and hardware. `-RequireUEFI` checks boot mode only;
  it does **not** check Secure Boot capability, TPM, CPU, storage capacity
  for the image, or servicing support. A no-parameter BIOS run is
  appropriate only when the task sequence deploys an OS supported in BIOS
  mode. For a legacy-only image, `-RequireBIOS` likewise blocks an accidental
  UEFI boot. The two requirement switches cannot be combined.

This is a **fresh-install** tool. Do not use it for in-place upgrades,
hard-link migrations, OEM/prestaged hard-disk media, or task sequences with
a client cache on a disk that might be erased. The script refuses detectable
cases. `clean` removes partition metadata; it is **not** secure erasure.
An existing BitLocker volume usually does not prevent cleaning a writable
disk, but a controller/driver/I/O failure or a locked hardware device can.

The `#requires -Version 5.1` directive deliberately excludes older
PowerShell 2/3/4 WinPE images. **ConfigMgr 2012-era environments are not
claimed as supported or tested.** This script cannot turn an old boot image
into a modern Storage WMI runtime. The last available x86 WinPE is the
Windows 10 version 2004 add-on; its ADK is **not** a supported site ADK for
current ConfigMgr, although older imported boot images can be used with
out-of-console customization. An x86 WinPE boot image, its PowerShell 5.1
and StorageWMI components, ConfigMgr COM hand-off, and its storage drivers
must be tested together. OS licensing/lifecycle support is a separate check.
Installing WMF 5.1 on an existing full Windows OS **does not install the
matching optional components into a separate WinPE boot image**. Having
`powershell.exe` available is necessary but not sufficient for this script.
Windows 10 22H2's normal support ended in October 2025; current ConfigMgr
lists it as a client **with ESU**, while LTSB/LTSC editions have separate
lifecycles. BIOS/MBR capability is not permission to deploy an unsupported
OS image.

When an otherwise UEFI-capable machine offers only **BIOS PXE**, booting
properly prepared **UEFI USB media** can select UEFI mode instead. Check the
firmware boot menu: `UEFI: USB` and `BIOS: USB` can boot the same media in
different modes. A genuinely **BIOS-only** machine cannot gain UEFI
firmware simply by using a USB drive; it takes the MBR path and still needs
a compatible operating-system image. No unsupported Windows 11 hardware
workaround is promised by this project.

| Scenario | Policy |
| --- | --- |
| UEFI-capable machine, UEFI boot | GPT by default; validate OS-image architecture and hardware |
| Legacy BIOS or CSM boot, 512n/512e disk up to 2 TB | MBR by default; use an OS image supporting BIOS |
| Windows 11-only task sequence | Add `-RequireUEFI`; independently check all Windows 11 requirements |
| Legacy-only task sequence | Add `-RequireBIOS` |
| BIOS boot with 4Kn media or disk over 2 TB | Stop before cleaning |
| Older x86 WinPE / older ConfigMgr site | Separate boot-image and task-sequence validation required; not certified |
| Existing-OS conversion or WinRE partition repair | Separate tools; this script would erase the installation |

## Preview and deployment

From a Windows PowerShell 5.1 session on a test machine, preview disk
enumeration and the layout without any disk changes:

```powershell
.\Invoke-OSDDiskLayout.ps1 -Preview
```

This preview may inspect the running Windows disk; **it never writes a
partition table, creates a DiskPart command file, or executes DiskPart**. It
prints the disk inventory, checks the selected disk's identity again, and
shows the exact proposed commands marked **NOT executed**. If a Surface
Storage Spaces guard blocks execution, the inventory is still printed first
so the reason can be investigated. A `-Preview` run inside a task sequence
returns failure deliberately, so a subsequent imaging step cannot proceed
from a preview.

In full Windows, `-Preview` assumes UEFI for the **plan only** unless
`-PreviewFirmware BIOS` is specified. This is simulation, not evidence of
the mode in which WinPE will later boot. In WinPE, a preview calls
`wpeutil UpdateBootInfo` (which updates WinPE registry boot information)
and follows the **actual** boot mode; `-PreviewFirmware` cannot override it.
Previewing a live, fully booted Windows machine is useful for selection and
size-policy checks, **not proof** that ConfigMgr's WinPE boot image will
enumerate the same disks or have the right drivers. Repeat the no-disk-write
preview using the actual WinPE boot image before any destructive field test.
In an active WinPE task sequence, preview also checks whether its own script,
log and task-sequence working data reside on the proposed target, and whether
the required temporary drive letters are available. It
intentionally marks the task-sequence status as failed and returns failure;
it is **disk-read-only**, not a promise that ConfigMgr itself writes no
cache, logs or task-sequence variables.

In a **test** task sequence:

1. Disable **every existing Format and Partition Disk step**, including any
   hard-coded Disk 0 / Disk 2 UEFI or BIOS steps. Use disposable test media.
2. Add one **Run PowerShell Script** action in WinPE before **Apply Operating
   System**. Package this script, leave **Output to task sequence variable**
   blank, and leave **Continue on error** unchecked. For an unsigned lab
   script, set that step's execution policy to **Bypass**; for a signed
   production script, use your signing policy instead. Ensure the package
   is distributed to the boot image's distribution points. Check the step
   timeout and whether its package/working data runs from the RAM drive,
   a network source, or another disk: **do not wipe the disk hosting the
   running task sequence**. The script stops if it detects this condition.
3. For a fleet known to have **one internal OS disk**, with no other
   plausible target, run with **no parameters** in the task sequence.
   The script accepts the only eligible disk at its actual disk number;
   it never assumes Disk 0. Boot UEFI for GPT or BIOS for MBR.
   **Windows 11-only sequences must pass `-RequireUEFI`** so an
   accidentally BIOS-booted machine is not wiped for an unusable install.

   For a multi-disk device, prefer an exact serial, or a tested cumulative
   bus + disk-model rule:

   ```text
   -TargetSerial "ACTUAL_DISK_SERIAL"
   -TargetBusType NVMe -TargetModelRegex "^APPROVED_DISK_MODEL"
   ```

   `TargetModelRegex` matches **the disk**, not the computer. Rules are always
   enforced, even if only one disk survives filtering. An ambiguous match
   fails; the script never falls back to Disk 0 or the smallest disk. Before
   cleaning, it also requires a serial, a unique PnP device ID, or a verified
   Storage Spaces virtual ID that can be rechecked after disk metadata changes.
   **A missing storage driver can make a multi-drive computer appear to
   have only one disk.** Never use the no-parameter policy on known
   multi-drive models without validating the boot-image drivers.
4. Keep the existing **Apply Operating System** destination variable
   `OSPART` (or the name supplied to `-OSPartitionVariable`). Gate that step
   or its enclosing fresh-install group on `DiskLayoutStatus = Success`,
   `DiskSelectionStatus = Success`, `DiskLayoutMode = FreshInstall`, and
   `OSPART` existing. For a Windows 11 image, also require
   `DiskPartitionStyle = GPT` and UEFI boot. Do not put a UEFI-only
   condition on the **layout step** if BIOS should be supported.
   Leave **Continue on error** unchecked. Do not run any later format step.
5. After setup and first boot, run `reagentc /info` and confirm WinRE is
   enabled and points to the Recovery partition. Also check that Recovery
   has enough free space for the deployed `winre.wim`, customizations and
   future servicing. This script only creates the partition; it does not
   copy or register WinRE, run BCDBoot, or prove that the OS installation
   populated it. Treat any repair or registration as a separate validated
   post-install operation, not an implicit side effect of formatting.

`-MinimumDiskSizeGB` and `-MaximumDiskSizeGB` use **decimal GB**, matching
marketed disk capacity. Defaults are 64 GB minimum and 8192 GB maximum.
`-MinimumDiskSizeGB` can be lowered to 32 **only as an explicit policy**;
use `-MinimumWindowsSizeGiB` to lower the default 40-GiB Windows minimum
(floor: 20 GiB). Partition sizes otherwise use **MiB**. A small partition
meeting Microsoft's installation minimum can still fail its separate
post-setup **16-GB free-space** requirement. Validate the real OS image
and updates before accepting smaller old disks. Increasing the disk maximum
also requires testing on that hardware.

Microsoft specifies the **order, type and minimum requirements**, not these
particular defaults: 1024-MiB EFI (UEFI), 512-MiB active System (BIOS) and
2048-MiB Recovery. For a tested image, size overrides are available:
`-EfiSizeMiB` (200-8192 on 512/512e, 300-8192 on 4Kn) for GPT;
`-BiosSystemSizeMiB` (100-8192) for MBR;
`-RecoverySizeMiB` (990-32768) for both. Firmware-inapplicable overrides
fail rather than silently being ignored. The GPT MSR remains 16 MiB under
current Windows UEFI/GPT guidance. Output names are limited to valid names,
must be distinct, and cannot overwrite the script's status variables or
ConfigMgr's `OSDTargetSystemDrive` output.

For a 120-GiB Windows partition and remaining NTFS Data space on a suitably
large disk, use the **explicit** optional profile:

```text
-WindowsSizeGiB 120 -CreateDataPartition
```

This creates EFI, MSR, Windows, Recovery, Data in UEFI or active System,
Windows, Recovery, Data in BIOS (all four MBR primary slots). Both options
must be provided together. Data has no assigned WinPE drive letter;
`DiskDataPartitionGuid` is available for GPT only. If a fixed `D:` is needed,
assign it in a **separate full-Windows step** after identifying the partition.
EFI must stay FAT32 and the other formatted partitions NTFS; arbitrary
filesystems, partition types, labels and counts are intentionally not exposed.
If a future BIOS-to-UEFI conversion is planned, prefer the three-partition
BIOS default: MBR2GPT validates **at most three primary partitions**, so an
optional fourth Data partition prevents direct conversion until the layout
is separately remediated.

### Surface Storage Spaces exception

Microsoft documents older 1-TB Surface configurations with **two physical
SSDs behind one Storage Spaces virtual disk**. The OS target can be Disk 2 or
Disk 3 if an SD card is present. The script does **not** guess either number.
For a positively identified, lab-validated affected model, the opt-in form is:

```text
-AllowSurfaceStorageSpaces -TargetBusType StorageSpaces -TargetComputerModelRegex "^YOUR_VALIDATED_SURFACE_MODEL$"
```

This requires Microsoft Surface manufacturer/model identification, a healthy
virtual disk, and a unique `Get-VirtualDisk` ↔ `Get-Disk` association. It
targets the **virtual** disk, not the underlying pool members. If WinPE cannot
expose and verify that association, the script stops. Verify the exact
`Win32_ComputerSystem.Model` value on your hardware before configuring the
regex. An ordinary target rule is blocked when Storage Spaces is visible;
on Surface, two 512-GB-class disks without a verified virtual target are a
stop signal, not two independent OS-disk choices. This exception is **not
field-validated here**.

`-AllowVirtualDisk -TargetBusType Virtual` is separately available for an
approved virtual-machine test group. SAS/SCSI buses require an explicit
`-TargetBusType` rule because they can also represent attached storage.
Use the actual WinPE inventory; a VM disk is not guaranteed to report
`BusType=Virtual`.

### Important detection limit

No WinPE script can identify a target it **cannot see**. For example, a
missing Intel VMD/RST driver can hide the OS SSD and leave a different data
disk visible; in some remapped RAID/Optane setups, constituent drives may
also appear as ordinary NVMe pass-through disks. Do not use the no-parameter
auto-selection path on hardware known to have multiple internal drives;
use a positive model/serial policy and validate the drivers in both the
boot image and deployed OS. A USB4/Thunderbolt NVMe enclosure may not
identify itself as `BusType=USB`, so bus type alone is never proof that a disk is internal.
`Get-Disk` also does not enumerate legacy dynamic disks: a visible-disk count
is not proof that every storage device has been inventoried.

## Scope and next profiles

This release is intentionally **one fresh-install engine**: UEFI/GPT has
four standard partitions (five with Data), and BIOS/MBR has three (four
with Data). The selection policy accepts 64-8192 GB decimal by default
(lower bound configurable to 32 GB, upper to 65536 GB), with at least
40 GiB planned for Windows by default; **the BIOS planner additionally
caps at 2 TB decimal**.
These limits mean it does *not* accept every disk size. It is not a universal
disk-connection detector. NVMe, SATA, ATA and RAID are candidates by default;
SAS/SCSI, VM disks and affected Surface Storage Spaces configurations need
explicit opt-in rules. USB, SD/MMC, iSCSI, Fibre Channel, file-backed and
unknown buses are not general OS targets. A controller/drive hidden from
WinPE cannot be safely selected.

Proposed extensions should be separate, testable profiles or tools:

1. **Further data-layout policies**: the current fixed-Windows plus
   remainder-Data profile exists, but additional partition recipes,
   filesystems and full-OS drive-letter assignment require their own tests.
2. **MBR-to-GPT of an existing OS**: separate validated `mbr2gpt` workflow.
   It converts a qualifying *system* disk rather than cleaning it; BitLocker,
   partition count, BCD and the subsequent UEFI firmware switch all matter.
3. **WinRE repair for an existing installation**: separate diagnose/repair
   tool with backup and explicit approval. Resizing may require disabling
   WinRE, shrinking Windows, replacing the existing Recovery partition and
   re-enabling WinRE. It must identify the actual WinRE location and handle
   non-adjacent/data-partition layouts; a fresh-install script must never
   attempt this during an upgrade.
4. **Advanced custom layouts**: if needed, use a versioned, validated schema
   with an approved list of partition types and invariants (ESP/MSR, Windows,
   adjacent WinRE, no overlaps, size/alignment limits). Arbitrary raw
   DiskPart command injection is deliberately out of scope.

## Validation gates before a release

First parse the script on a Windows PowerShell 5.1 test machine; parsing
is non-destructive and does not require Pester:

```powershell
$scriptPath = (Resolve-Path .\Invoke-OSDDiskLayout.ps1).Path
$tokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { $parseErrors | Format-List; throw 'Parse failed' }
```

The supplied Pester tests exercise pure selection, calculation, and
synthetic post-format validation without executing the script's entry
point or calling DiskPart:

```powershell
Invoke-Pester -Path .\tests\Invoke-OSDDiskLayout.Tests.ps1
```

The authored Pester tests run without disk writes in Windows PowerShell 5.1.
They are not a replacement for tests on disposable storage in your actual
task sequence.

| Test fixture | Expected result |
| --- | --- |
| UEFI WinPE task sequence, only internal Disk 2, no parameters | Select and format Disk 2 as GPT on disposable media |
| BIOS WinPE task sequence, only internal Disk 3, no parameters | Select and format Disk 3 as MBR with active System and Recovery ID 27 |
| BIOS WinPE task sequence with `-RequireUEFI` | Stop before `clean` |
| UEFI WinPE task sequence with `-RequireBIOS` | Stop before `clean` |
| Missing or contradictory ConfigMgr `_SMSTSBootUEFI` | Use detected WinPE mode only if missing; reject a contradiction |
| No parameters outside an active task sequence | Refuse destructive execution |
| Full Windows `-Preview -PreviewFirmware BIOS` | Show a simulated MBR plan; write no disk changes |
| WinPE package or `_SMSTSMDataPath` on selected disk | Stop before `clean`; move the task-sequence content off-target |
| USB Disk 0 + internal Disk 2 | Ignore USB, select only the eligible internal disk |
| Two internal disks, no unique rule | Stop before `clean` |
| Approved serial absent; one data disk remains | Stop; never ignore the supplied serial |
| Surface Storage Spaces Disk 2 or 3 plus pool members / SD | Select virtual disk only with the specific opt-in and unique mapping |
| Intel VMD/RST target invisible, only USB visible | Stop; correct boot-image drivers |
| External UASP/SCSI, offline disk, unhealthy disk | Reject or require an explicit approved exception |
| USB4/Thunderbolt NVMe reported like an internal disk | Treat bus detection as inconclusive; require a tested positive identity rule |
| BIOS on 512e versus 4Kn or disk over 2 TB; occupied `S:`/`W:` | Enforce guards and verify layout on actual hardware |
| Older x86 WinPE with supported OS, components and storage driver | Verify firmware detection, Storage WMI, COM, DiskPart and image hand-off |
| DiskPart error at each command, unexpected result | Fail, clear outputs, never apply OS |
| Successful OS apply and first boot | `OSPART` hand-off works; WinRE reports Enabled in the right place |
| Fixed-size Windows and optional Data profile | Recovery stays adjacent to Windows, Data is last and NTFS |

Save `smsts.log` and disk inventory from failed runs before reboot; WinPE's
temporary drive may not retain logs. Your existing log-copy task-sequence
script can remain a **separate step** after an appropriate failure path.
Redact device serials and other inventory identifiers before posting logs
to a public issue.

## Related projects

- [Copy OSD logs to a file share](https://github.com/vartaxe/ConfigMgr-OSD-CopyOSDLogToFileShare) is a separate diagnostics step; this script does not send logs off the device.
- [Add a computer to an AD group](https://github.com/vartaxe/ConfigMgr-OSD-AddComputerToADGroup) belongs after the OS/domain-join portion of deployment, not in this WinPE disk step.

## References

- Microsoft: [UEFI/GPT-based hard drive partitions](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions?view=windows-11) (current layout and WinRE sizing).
- Microsoft: [BIOS/MBR-based hard drive partitions](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-biosmbr-based-hard-drive-partitions?view=windows-11) (active system, Recovery `0x27`, four primary slots).
- Microsoft: [Wpeutil UpdateBootInfo](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/wpeutil-command-line-options?view=windows-11) (WinPE firmware type registry values).
- Microsoft: [MSFT_Partition properties](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition) (MBR type, IsActive, GPT-only GUID and no-default-letter).
- Microsoft: [Hard drives and partitions](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/hard-drives-and-partitions?view=windows-11) (512e BIOS/UEFI, 4Kn UEFI-only, disk numbers can change).
- Microsoft: [Boot to UEFI or legacy BIOS](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/boot-to-uefi-mode-or-legacy-bios-mode?view=windows-11) (UEFI/BIOS entries for the same USB media and WinPE firmware detection).
- Microsoft: [Surface 1-TB Storage Spaces disk numbering](https://learn.microsoft.com/en-us/troubleshoot/devices/disk0-not-found-deploy-windows-surface-device-1tb-drive-configuration).
- Microsoft: [Surface 1-TB configuration showing two drives](https://learn.microsoft.com/en-us/troubleshoot/devices/surface-device-1tb-drive-configuration-shows-two-drives) (older tools can break the virtual drive).
- Dynabook: [Intel RST/Optane driver caveat](https://aps2.support.emea.dynabook.com/kb0/TSB0303YB0000R01.htm) (remapped constituent disks may appear as pass-through drives).
- Microsoft: [PowerShell support in WinPE](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-adding-powershell-support-to-windows-pe?view=windows-11).
- Microsoft: [WinPE optional component dependencies](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11), [Run PowerShell Script step](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/new-cmtssteprunpowershellscript?view=sccm-ps), and [Windows 11 requirements](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements).
- Microsoft: [Supported ConfigMgr ADK versions and last x86 WinPE](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/support-for-windows-adk) and [older boot image customization](https://learn.microsoft.com/en-us/intune/configmgr/osd/get-started/customize-boot-images).
- Microsoft: [ConfigMgr support for Windows 10](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/support-for-windows-10) and [Windows 10 ESU](https://learn.microsoft.com/en-us/windows/whats-new/extended-security-updates).
- Microsoft: [DiskPart scripts and examples](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart-scripts-and-examples).
- Microsoft: [Deploy Windows RE](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deploy-windows-re?view=windows-11).
- Microsoft: [Task sequence variable reference](https://learn.microsoft.com/en-us/intune/configmgr/osd/understand/task-sequence-variables) and [Apply OS Image destination](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/new-cmtsstepapplyoperatingsystem?view=sccm-ps).
- Microsoft: [Get-Disk](https://learn.microsoft.com/en-us/powershell/module/storage/get-disk?view=windowsserver2025-ps) (enumeration and dynamic-disk limitation).
- Microsoft: [MBR2GPT](https://learn.microsoft.com/en-us/windows/deployment/mbr-to-gpt) (conversion prerequisites and UEFI switch).
- Microsoft: [WinRE partition resizing](https://support.microsoft.com/en-us/servicing/os/windows/2023/06/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update) (existing-OS repair path).

This preview does not imply a completed release or warranty.
