# Configuration Manager task-sequence integration

**Companion to `Invoke-OSDDiskLayout.ps1` (0.5.1-rc.1). Not field-certified.**
Use disposable media and a copy of the task sequence for the first tests.
In an active WinPE task sequence, running the script without `-Preview`
**erases the selected disk**. Do not add a native Format and Partition Disk
step after it.

## Recommended structure

```text
Install operating system / fresh-install branch
  00  Restart in Windows PE
  05  Check Readiness / confirm image and firmware policy (optional)
  10  Run PowerShell Script: Invoke-OSDDiskLayout.ps1
  20  Pre-provision BitLocker (optional, if boot image and policy allow)
  30  Apply Operating System Image -> OSPART
  40  Apply boot-critical and other device drivers
  50  Setup Windows and Configuration Manager
  60  Restart into the installed OS
  70  Validate boot, partition layout, and WinRE
```

The one PowerShell action **replaces every Disk 0, Disk 2, BIOS and UEFI
Format and Partition Disk action** in the same install path. Do not leave a
second formatter enabled or add a fallback formatter after an error. A
missing layout result must stop deployment; it must not cause the image to
use "next available formatted partition." For an in-place upgrade, use a
**different branch**: this script never preserves the installed OS.

### Before the layout step

- Boot the actual ConfigMgr WinPE image with Windows PowerShell 5.1, its
  dependent WinPE optional components (WMI, NetFX and Scripting), StorageWMI,
  the Configuration Manager task-sequence runtime and storage drivers. WMF
  installed in full Windows does not add components to WinPE.
- Validate Intel VMD/RST/RAID and Surface Storage Spaces topology in this
  exact boot image. A missing driver can hide the intended drive or present
  constituent drives differently. An unusual Disk 2 or Disk 3 is not, by
  itself, a reason to choose Disk 0.
- Keep the task-sequence working data, script package and logs **off the
  target disk**. The script checks `_SMSTSMDataPath`, `_SMSTSLogPath` and its
  own path before cleaning; if it cannot establish a safe location, it stops.
  It does not migrate ConfigMgr's working directory automatically.
- Run any OS-specific hardware checks before the destructive step. A
  Windows 11-only sequence needs a supported image and separate hardware
  readiness checks; `-RequireUEFI` only enforces the firmware mode.
- If a custom unattend answer file is enabled on Apply OS Image, inspect
  its `Microsoft-Windows-Setup/DiskConfiguration` and
  `ImageInstall/OSImage/InstallTo` settings. Do not allow the answer file to
  repartition a second disk or override the destination selected by the
  task sequence. Without the answer file's contents, its safety cannot
  be inferred from the editor checkbox.

### Step 10: Run PowerShell Script

| Setting | Recommended value |
| --- | --- |
| Name | `Partition selected OS disk (UEFI/GPT or BIOS/MBR)` |
| Script source | Package containing `Invoke-OSDDiskLayout.ps1`; reference that script by name |
| Parameters: normal Windows 10 / dual-mode profile | Blank (auto-selects by actual WinPE boot mode) |
| Parameters: Windows 11-only profile | `-RequireUEFI` |
| Parameters: legacy BIOS-only OS profile | `-RequireBIOS` |
| Parameters: approved multi-disk model | Add a **tested, unique** `-TargetSerial` or cumulative disk-bus/model rule |
| Execution policy | `Bypass` for an unsigned lab script; use the organization's signing policy for signed production code |
| Output to task sequence variable | **Blank**; the script itself sets `OSPART`, `OSDDiskIndex` and status values through the TS environment |
| Continue on error | **Unchecked** |
| Success codes | Default success only (`0`); do not make a nonzero code successful |
| Timeout | Verify the configured limit; the step normally defaults to 15 minutes. Adjust only after testing the target hardware |
| Step conditions | Do not use Disk 0/Disk 2 WMI size queries or a UEFI-only condition on an auto-firmware step |

The **Parameters** box contains only parameters, not a second
`powershell.exe` command or the script filename. For example, a Windows
11-only step has `-RequireUEFI` there. Do not combine `-RequireUEFI` and
`-RequireBIOS`.

For a known 32-GB-class legacy disk, the default 64-GB selection floor and
40-GiB Windows minimum are intentionally conservative. Only after testing
the actual OS image, an explicit policy might use:

```text
-RequireBIOS -MinimumDiskSizeGB 32 -MinimumWindowsSizeGiB 24
```

This merely allows planning a smaller partition. It does **not** ensure
adequate free space after setup and servicing. A fixed 120-GiB Windows
partition plus a remaining NTFS Data partition instead uses
`-WindowsSizeGiB 120 -CreateDataPartition`. The BIOS Data variant fills
the fourth MBR primary slot and blocks a direct future MBR2GPT conversion.

### Step 20: optional BitLocker preparation

If the task sequence uses ConfigMgr Pre-provision BitLocker, put it **after
successful partitioning and before Apply OS Image**. The boot image needs
its own BitLocker/TPM support (WinPE-SecureStartup). Do not make this a
silent side effect of the disk-layout script. If a prerequisite fails,
do not use "Continue on error" to mask a failed OS layout.

### Step 30: Apply Operating System Image

In the **Destination** setting select **Logical drive letter stored in a
variable**, then enter `OSPART` as the **variable name** (no `%` characters,
no `W:` literal). The script puts `W:` in `OSPART` only **after** it verifies
the chosen disk's partition style, partition order, Windows filesystem and
temporary letter. If `-OSPartitionVariable` is changed, enter that custom
variable name here instead.

Gate Apply OS Image, or the group containing all downstream install steps,
on these custom-variable conditions:

```text
DiskLayoutStatus      equals  Success
DiskSelectionStatus   equals  Success
DiskLayoutMode        equals  FreshInstall
OSPART                exists
```

For a **Windows 11-only** image also require:

```text
DiskPartitionStyle    equals  GPT
_SMSTSBootUEFI        equals  true
```

The extra Windows 11 conditions are defense in depth, not a substitute
for the layout step's `-RequireUEFI`. When BIOS boot is allowed for a
compatible image, **do not** gate this shared install branch on
`DiskPartitionStyle=GPT`.

Keep **Continue on error unchecked** for Apply OS Image and Setup Windows
and Configuration Manager. Never fall back to ConfigMgr's default "next
available formatted partition." The custom `OSDDiskIndex` is diagnostic;
this script does not hand a disk/partition pair to Apply OS. The built-in
`OSDTargetSystemDrive` is an **output of Apply OS Image**, not the script's
input or a replacement for `OSPART`.

### Step 40 onward: first boot and validation

Apply storage and other boot-critical drivers before the first boot into
the new OS. The disk script cannot install those drivers in the applied
Windows image. After Windows setup, validate with `reagentc /info` and
inspect the disk layout: GPT or MBR matches the actual firmware, Windows
is installed on the intended disk, and WinRE is enabled and located on
the adjacent Recovery partition with enough free space. Creation of a
correctly typed Recovery partition alone does **not** copy or register
`winre.wim`; put any WinRE repair in a separate, validated post-install
operation. Do not insert BCDBoot into this partition step without testing
the actual ConfigMgr image-application and setup workflow.

## Variables and checks

| Variable | Meaning / safe use |
| --- | --- |
| `_SMSTSInWinPE` | Must be `true` for execution; the script enforces it. |
| `_SMSTSBootUEFI` | ConfigMgr firmware indicator; the script compares it with `PEFirmwareType` when set and stops on a contradiction. Do not set it yourself. |
| `OSDMigrateUseHardlinks` | `true` stops this fresh-install script. |
| `_SMSTSClientCache` | Nonempty client-cache path stops destructive execution. |
| `_SMSTSMediaType`, `_SMSTSLaunchMode` | OEM media or prestaged hard-disk boot modes stop destructive execution. |
| `_SMSTSMDataPath`, `_SMSTSLogPath` | Working-data/log locations checked against the selected physical disk. |
| `OSDTargetSystemDrive` | Apply OS Image output; a pre-existing value stops the disk script. |
| `OSDDiskIndex` | Selected disk number for diagnostics; do not hard-code it to `0`. |
| `OSPART` | Verified temporary Windows drive (`W:`); destination variable for Apply OS Image. |
| `DiskSelectionStatus`, `DiskLayoutStatus` | Both `Success` only after formatting and validation; `Failed` on errors. |
| `DiskLayoutMode`, `DiskPartitionStyle` | `FreshInstall` and `GPT`/`MBR` after success. |
| `DiskDataPartitionGuid` | Optional GPT Data partition only; MBR has no GPT partition GUID. |

**Do not add `_SMSTSBootUEFI = true` to the parent layout group** if the same
script is intended to partition both UEFI and BIOS devices. Conversely,
if the task sequence applies only a Windows 11 image, an existing enabled
BIOS format step must not remain under that image. Passing `-RequireUEFI`
causes an accidental BIOS boot to fail **before** `clean` rather than
silently skipping the layout step and running Apply OS with stale state.
Likewise, do not leave multiple overlapping disk-size WMI conditions
that could execute two formatters.

## Non-destructive rollout

1. On a running test computer, use `-Preview` for a disk inventory and
   simulated layout. For a BIOS plan from full Windows, add
   `-PreviewFirmware BIOS`. Full Windows cannot prove how the WinPE driver
   stack will enumerate disks.
2. Run `-Preview` under the **actual WinPE boot image**; inside a task
   sequence it deliberately returns a failing step and sets layout
   status to `Failed`, so no Apply OS action should proceed. It emits
   proposed DiskPart commands but creates no command file and never
   invokes DiskPart.
3. Test the actual destructive branch only on a **disposable** disk,
   first in UEFI and then in BIOS when that mode is in scope. Verify a
   sole internal Disk 2/3, ambiguous multi-disk, occupied `S:`/`W:`,
   cached content on target, bad storage drivers and error handling.
4. Confirm Apply OS Image uses `OSPART` and inspect the first boot,
   partition types/attributes and `reagentc /info`. Save logs before
   reboot and redact inventory identifiers before sharing publicly.

## Source guidance

- [ConfigMgr task sequence steps](https://learn.microsoft.com/en-us/intune/configmgr/osd/understand/task-sequence-steps) and [variable reference](https://learn.microsoft.com/en-us/intune/configmgr/osd/understand/task-sequence-variables)
- [Run PowerShell Script step](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/new-cmtssteprunpowershellscript?view=sccm-ps) and [Apply OS Image destination](https://learn.microsoft.com/en-us/powershell/module/configurationmanager/new-cmtsstepapplyoperatingsystem?view=sccm-ps)
- [WinPE PowerShell dependencies](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-adding-powershell-support-to-windows-pe?view=windows-11) and [WinPE optional components](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference?view=windows-11)
- [UEFI/GPT](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions?view=windows-11), [BIOS/MBR](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-biosmbr-based-hard-drive-partitions?view=windows-11), and [WinRE deployment](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deploy-windows-re?view=windows-11)
