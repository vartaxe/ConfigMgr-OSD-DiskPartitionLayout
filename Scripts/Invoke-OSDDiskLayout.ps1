#requires -Version 5.1
<#
.SYNOPSIS
    Selects one approved target and creates a firmware-appropriate GPT or MBR
    layout in one Configuration Manager Run PowerShell Script step.
.DESCRIPTION
    In an active WinPE task sequence, NO PARAMETERS irreversibly erase the
    only eligible internal disk. UEFI boot creates GPT/EFI/MSR/Windows/Recovery;
    legacy BIOS boot creates MBR/active System/Windows/Recovery.
    Zero or multiple eligible disks stop before any disk modification.
    Outside a task sequence, no-parameter execution refuses to run; use
    -Preview to inventory disks without changing them.
    Default UEFI: EFI 1024 MiB | MSR 16 MiB | Windows | Recovery 2048 MiB.
    Default BIOS: System 512 MiB | Windows | Recovery 2048 MiB.
    Microsoft recommends the partition order/types, not these fixed EFI and
    Recovery sizes; they are conservative, configurable choices.
    Up to 32 MiB is reserved for alignment and disk metadata; the Recovery
    partition is last but a small tail may remain unallocated.
    This script does not apply Windows or configure WinRE after setup.
    On BIOS hardware, use a compatible Windows 10 (or other supported legacy)
    image. A Windows 11 image cannot boot from the BIOS/MBR layout.

    A disk hidden by a missing WinPE storage driver cannot be discovered;
    single-disk mode is inappropriate on known multi-drive hardware.
.PARAMETER Preview
    Read-only inventory and layout plan. In a task sequence this deliberately
    fails the step after preview, so Apply OS cannot continue accidentally.
.PARAMETER PreviewFirmware
    UEFI or BIOS layout to simulate from a full Windows preview. In WinPE the
    detected actual boot mode is authoritative and must match this option.
.PARAMETER RequireUEFI
    Stop before clean if the detected boot mode is BIOS. Set this on Windows
    11-only task sequences to avoid creating an incompatible MBR layout.
.PARAMETER RequireBIOS
    Stop before clean if WinPE booted in UEFI mode. Use only when the OS
    image/task sequence is explicitly limited to legacy BIOS.
.PARAMETER AllowVirtualDisk
    Allows a virtual-machine target only with -TargetBusType Virtual.
.PARAMETER TargetSerial
    Exact Get-Disk serial number. Preferred for model-specific exceptions.
.PARAMETER TargetModelRegex
    Regex for Get-Disk.FriendlyName (DISK model, not computer model).
.PARAMETER TargetComputerModelRegex
    Regex for Win32_ComputerSystem.Model. Required for Storage Spaces mode.
.PARAMETER TargetBusType
    Optional bus filter. StorageSpaces maps to the Storage Spaces virtual bus.
.PARAMETER AllowSurfaceStorageSpaces
    Enables an explicitly identified Surface Storage Spaces virtual target with
    -TargetBusType StorageSpaces and -TargetComputerModelRegex. The virtual
    disk must map uniquely to Get-VirtualDisk; pool member disks are not used.
.PARAMETER MinimumDiskSizeGB
    Minimum candidate size in decimal GB. Default: 64.
.PARAMETER MinimumWindowsSizeGiB
    Minimum planned Windows partition in GiB. Default: 40. Reducing it
    does not prove the image will have enough post-setup free space.
.PARAMETER MaximumDiskSizeGB
    Maximum candidate size in decimal GB. Default: 8192; can be raised.
.PARAMETER EfiSizeMiB
    EFI partition size in MiB. Default: 1024; minimum: 200 for 512-byte
    logical sectors or 300 for 4Kn storage.
.PARAMETER BiosSystemSizeMiB
    Active NTFS system partition size in BIOS/MBR mode. Default: 512 MiB.
.PARAMETER RecoverySizeMiB
    Recovery partition size in MiB. Default: 2048; minimum: 990.
.PARAMETER WindowsSizeGiB
    Optional fixed Windows size (GiB); only valid with -CreateDataPartition.
.PARAMETER CreateDataPartition
    Adds an NTFS Data partition after Recovery using remaining space.
    Requires -WindowsSizeGiB; the partition is not assigned a drive letter.
.PARAMETER OSPartitionVariable
    Task-sequence variable receiving the temporary Windows drive, default OSPART.
.PARAMETER DiskNumberVariable
    Task-sequence variable receiving the selected disk number, default OSDDiskIndex.
.PARAMETER MinimumTargetSizeGB
    Optional additional inclusive lower bound for an approved target rule.
.PARAMETER MaximumTargetSizeGB
    Optional additional inclusive upper bound for an approved target rule.
.EXAMPLE
    .\Invoke-OSDDiskLayout.ps1
    In a ConfigMgr WinPE task sequence, choose GPT or MBR by actual boot mode.
.EXAMPLE
    .\Invoke-OSDDiskLayout.ps1 -Preview -PreviewFirmware BIOS
    Read-only BIOS/MBR plan from full Windows without disk writes.
.EXAMPLE
    .\Invoke-OSDDiskLayout.ps1 -RequireUEFI -TargetBusType NVMe -TargetModelRegex '^Approved SSD model'
    An approved, unique disk rule for a specific model group.
.NOTES
    Version: 1.0.0. Not validated on live x86 or x64 WinPE hardware.
    Never follow this step with another Format and Partition Disk action.
    Apply Operating System must use OSPART, or the custom OSPartitionVariable.
#>
[CmdletBinding()]
param(
    [switch] $Preview,
    [ValidateSet('UEFI', 'BIOS')]
    [string] $PreviewFirmware,
    [switch] $RequireUEFI,
    [switch] $RequireBIOS,
    [switch] $AllowVirtualDisk,
    [switch] $AllowSurfaceStorageSpaces,
    [string] $TargetSerial = '',
    [string] $TargetModelRegex = '',
    [string] $TargetComputerModelRegex = '',
    [ValidateSet('', 'NVMe', 'SATA', 'SAS', 'RAID', 'ATA', 'SCSI', 'Virtual', 'StorageSpaces')]
    [string] $TargetBusType = '',
    [ValidateRange(32, 65536)]
    [int] $MinimumDiskSizeGB = 64,
    [ValidateRange(32, 65536)]
    [int] $MaximumDiskSizeGB = 8192,
    [ValidateRange(20, 1024)]
    [int] $MinimumWindowsSizeGiB = 40,
    [ValidateRange(0, 65536)]
    [int] $MinimumTargetSizeGB = 0,
    [ValidateRange(0, 65536)]
    [int] $MaximumTargetSizeGB = 0,
    [ValidateRange(200, 8192)]
    [int] $EfiSizeMiB = 1024,
    [ValidateRange(100, 8192)]
    [int] $BiosSystemSizeMiB = 512,
    [ValidateRange(990, 32768)]
    [int] $RecoverySizeMiB = 2048,
    [ValidateRange(0, 65536)]
    [int] $WindowsSizeGiB = 0,
    [switch] $CreateDataPartition,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,255}$')]
    [string] $OSPartitionVariable = 'OSPART',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,255}$')]
    [string] $DiskNumberVariable = 'OSDDiskIndex'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:TSEnv = $null
$PlanPath = $null
$EfiMiB = $EfiSizeMiB
$MsrMiB = 16
$RecoveryMiB = $RecoverySizeMiB
$AlignmentReserveMiB = 32
$RecoveryGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

function Set-TSValue {
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowEmptyString()][string] $Value
    )
    if ($script:TSEnv) {
        $script:TSEnv.Value($Name) = $Value
    }
}

function ConvertTo-OSDBusType {
    param([string] $BusType)
    if ($BusType -in @('Storage Spaces', 'Spaces', 'StorageSpaces')) {
        return 'StorageSpaces'
    }
    return $BusType
}

function Test-OSDRegexMatch {
    param(
        [AllowEmptyString()][string] $Value,
        [Parameter(Mandatory)][string] $Pattern
    )
    try {
        return [regex]::IsMatch($Value, $Pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
            [timespan]::FromSeconds(1))
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        throw 'Approved disk or computer model pattern took too long to match.'
    }
    catch [System.ArgumentException] {
        throw 'Approved disk or computer model pattern is not a valid regex.'
    }
}

function ConvertFrom-PEFirmwareType {
    param([Parameter(Mandatory)][int] $Value)
    switch ($Value) {
        1 { return 'BIOS' }
        2 { return 'UEFI' }
        default { throw "Unknown WinPE firmware mode: $Value" }
    }
}

function Resolve-OSDFirmwareMode {
    param(
        [Parameter(Mandatory)][int] $PEFirmwareType,
        [string] $TaskSequenceUEFIFlag = '',
        [string] $SimulatedFirmware = ''
    )

    $Mode = ConvertFrom-PEFirmwareType -Value $PEFirmwareType
    if ($TaskSequenceUEFIFlag -and
        $TaskSequenceUEFIFlag -notin @('true', 'false')) {
        throw 'ConfigMgr reported an unrecognized firmware flag.'
    }
    if (($TaskSequenceUEFIFlag -ieq 'true' -and $Mode -ne 'UEFI') -or
        ($TaskSequenceUEFIFlag -ieq 'false' -and $Mode -ne 'BIOS')) {
        throw 'WinPE firmware detection conflicts with the ConfigMgr firmware flag.'
    }
    if ($SimulatedFirmware -and $Mode -ne $SimulatedFirmware) {
        throw 'Requested preview firmware differs from the actual WinPE boot mode.'
    }
    return $Mode
}

function Assert-OSDFirmwarePolicy {
    param(
        [Parameter(Mandatory)][ValidateSet('UEFI', 'BIOS')]
        [string] $FirmwareMode,
        [bool] $RequireUEFI,
        [bool] $RequireBIOS
    )
    if ($RequireUEFI -and $RequireBIOS) {
        throw 'Cannot require both UEFI and BIOS boot.'
    }
    if ($RequireUEFI -and $FirmwareMode -ne 'UEFI') {
        throw 'This task sequence requires UEFI, but WinPE booted in legacy BIOS mode.'
    }
    if ($RequireBIOS -and $FirmwareMode -ne 'BIOS') {
        throw 'This task sequence requires legacy BIOS, but WinPE booted in UEFI mode.'
    }
}

function Test-OSDDiskEligible {
    param(
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)][string[]] $AllowedBuses,
        [Parameter(Mandatory)][int] $MinimumDiskSizeGB,
        [int] $MaximumDiskSizeGB = 8192,
        [bool] $AllowStorageSpacesDisk = $false
    )

    $Reasons = @()
    if ($Item.BusType -notin $AllowedBuses) {
        $Reasons += "unapproved bus $($Item.BusType)"
    }
    if ($Item.BusType -eq 'StorageSpaces' -and
        (-not $AllowStorageSpacesDisk -or -not $Item.VirtualVerified)) {
        $Reasons += 'Storage Spaces virtual disk not verified'
    }
    if (-not $Item.WmiFound -and
        -not ($Item.BusType -eq 'StorageSpaces' -and
             $AllowStorageSpacesDisk -and $Item.VirtualVerified)) {
        $Reasons += 'no device inventory'
    }
    if ($Item.IsOffline -or $Item.IsReadOnly -or $Item.IsClustered) {
        $Reasons += 'offline, read-only, or clustered'
    }
    if ($Item.HealthStatus -notin @('Healthy', 'Unknown') -or
        ($Item.BusType -eq 'StorageSpaces' -and $Item.HealthStatus -ne 'Healthy')) {
        $Reasons += "health $($Item.HealthStatus)"
    }
    if ($Item.SizeBytes -lt ([uint64]$MinimumDiskSizeGB * 1000000000)) {
        $Reasons += 'below minimum size'
    }
    if ($Item.SizeBytes -gt ([uint64]$MaximumDiskSizeGB * 1000000000)) {
        $Reasons += 'above maximum size'
    }
    if ($Item.WmiFound -and
        (($Item.WmiInterface -eq 'USB') -or
         ($Item.WmiMedia -match 'Removable|External') -or
         ($Item.PnpId -match '^(USBSTOR|UASPSTOR|USB)\\') -or
         ($Item.WmiStatus -notin @('', 'OK', 'Unknown')))) {
        $Reasons += 'removable, external, or unhealthy device'
    }

    return [pscustomobject]@{
        Eligible = ($Reasons.Count -eq 0)
        Reasons = ($Reasons -join '; ')
    }
}

function Select-OSDTargetDisk {
    param(
        [Parameter(Mandatory)][object[]] $Inventory,
        [string] $TargetSerial = '',
        [string] $TargetModelRegex = '',
        [string] $TargetBusType = '',
        [int] $MinimumDiskSizeGB = 64,
        [int] $MinimumTargetSizeGB = 0,
        [int] $MaximumTargetSizeGB = 0
    )

    $HasRule = [bool]($TargetSerial -or $TargetModelRegex -or $TargetBusType -or
        $MinimumTargetSizeGB -or $MaximumTargetSizeGB)
    $Eligible = @($Inventory | Where-Object { $_.Eligible })
    if ($Eligible.Count -gt 1 -and -not $HasRule) {
        throw 'Multiple eligible disks; supply a unique target rule before formatting.'
    }
    if ($Eligible.Count -gt 1 -and
        -not ($TargetSerial -or $TargetModelRegex -or $TargetBusType)) {
        throw 'Size-only rules cannot authorize a multi-disk deployment.'
    }

    $Matched = @($Eligible)
    if ($TargetSerial) {
        $Matched = @($Matched | Where-Object { $_.Serial -ieq $TargetSerial })
    }
    if ($TargetModelRegex) {
        $Matched = @($Matched | Where-Object {
            Test-OSDRegexMatch -Value $_.Model -Pattern $TargetModelRegex
        })
    }
    if ($TargetBusType) {
        $Matched = @($Matched | Where-Object { $_.BusType -eq $TargetBusType })
    }
    if ($MinimumTargetSizeGB -gt 0) {
        $Matched = @($Matched | Where-Object {
            $_.SizeBytes -ge ([uint64]$MinimumTargetSizeGB * 1000000000)
        })
    }
    if ($MaximumTargetSizeGB -gt 0) {
        $Matched = @($Matched | Where-Object {
            $_.SizeBytes -le ([uint64]$MaximumTargetSizeGB * 1000000000)
        })
    }

    if (-not $HasRule) {
        $KnownExternalBuses = @(
            'USB', 'SD', 'MMC', 'iSCSI', 'Fibre Channel',
            'File Backed Virtual', '1394'
        )
        $Uncertain = @($Inventory | Where-Object {
            (-not $_.Eligible) -and
            ($_.SizeBytes -ge ([uint64]$MinimumDiskSizeGB * 1000000000)) -and
            ($_.BusType -notin $KnownExternalBuses)
        })
        if ($Uncertain.Count -gt 0) {
            throw 'Another potentially internal disk is present but ineligible; use an explicit target rule.'
        }
    }
    if ($Matched.Count -ne 1) {
        throw "Expected exactly one approved disk; matched $($Matched.Count). No disk was changed."
    }

    $Selected = $Matched[0]
    if (-not $Selected.Serial -and -not $Selected.PnpId -and
        -not ($Selected.VirtualVerified -and $Selected.VirtualId)) {
        throw 'Selected disk lacks a serial, PnP device ID, or verified virtual ID that survives cleanup.'
    }
    if ($Selected.Serial -and
        @($Inventory | Where-Object { $_.Serial -ieq $Selected.Serial }).Count -ne 1) {
        throw 'Selected disk serial is not unique among visible disks.'
    }
    if ($Selected.VirtualId -and
        @($Inventory | Where-Object { $_.VirtualId -eq $Selected.VirtualId }).Count -ne 1) {
        throw 'Selected virtual disk ID is not unique among visible disks.'
    }
    if (-not $Selected.Serial -and -not $Selected.VirtualVerified -and $Selected.PnpId -and
        @($Inventory | Where-Object { $_.PnpId -eq $Selected.PnpId }).Count -ne 1) {
        throw 'Selected PnP device ID is not unique among visible disks.'
    }
    return $Selected
}

function Assert-OSDFirmwareDiskGeometry {
    param(
        [Parameter(Mandatory)] $Disk,
        [Parameter(Mandatory)][ValidateSet('UEFI', 'BIOS')]
        [string] $FirmwareMode,
        [int] $EfiMiB = 1024
    )
    if ($Disk.LogicalSectorSize -notin @(512, 4096)) {
        throw 'Only 512-byte or 4096-byte logical sectors are supported for Windows boot.'
    }
    if ($FirmwareMode -eq 'BIOS') {
        if ($Disk.LogicalSectorSize -ne 512) {
            throw 'BIOS/MBR mode requires 512-byte logical sectors; 4Kn is unsupported.'
        }
        if ($Disk.SizeBytes -gt [uint64]2000000000000) {
            throw 'BIOS/MBR mode refuses disks larger than 2 TB decimal.'
        }
    }
    elseif (($Disk.LogicalSectorSize -eq 4096 -and $EfiMiB -lt 300) -or
            ($Disk.LogicalSectorSize -eq 512 -and $EfiMiB -lt 200)) {
        throw 'EFI partition is below the minimum for this logical sector size.'
    }
}

function New-OSDPartitionPlan {
    param(
        [Parameter(Mandatory)][uint64] $DiskSizeBytes,
        [ValidateSet('UEFI', 'BIOS')][string] $FirmwareMode = 'UEFI',
        [int] $EfiMiB = 1024,
        [int] $BiosSystemMiB = 512,
        [int] $MsrMiB = 16,
        [int] $RecoveryMiB = 2048,
        [int] $AlignmentReserveMiB = 32,
        [int] $WindowsSizeGiB = 0,
        [int] $MinimumWindowsSizeGiB = 40,
        [bool] $CreateDataPartition = $false
    )

    if ($FirmwareMode -eq 'BIOS' -and $DiskSizeBytes -gt [uint64]2000000000000) {
        throw 'BIOS/MBR profile refuses disks larger than 2 TB decimal.'
    }
    $BootMiB = $EfiMiB
    $ReservedMiB = $MsrMiB
    $ActualEfiMiB = $EfiMiB
    $ActualBiosSystemMiB = 0
    if ($FirmwareMode -eq 'BIOS') {
        $BootMiB = $BiosSystemMiB
        $ReservedMiB = 0
        $ActualEfiMiB = 0
        $ActualBiosSystemMiB = $BiosSystemMiB
    }
    $TotalMiB = [int64][math]::Floor($DiskSizeBytes / 1MB)
    $AvailableMiB = $TotalMiB - $BootMiB - $ReservedMiB - $RecoveryMiB - $AlignmentReserveMiB
    if ($CreateDataPartition -ne ($WindowsSizeGiB -gt 0)) {
        throw 'Data layout requires both -CreateDataPartition and -WindowsSizeGiB.'
    }
    $DataMiB = [int64]0
    $WindowsMiB = $AvailableMiB
    if ($CreateDataPartition) {
        $WindowsMiB = [int64]$WindowsSizeGiB * 1024
        $DataMiB = $AvailableMiB - $WindowsMiB
        if ($DataMiB -lt 1024) {
            throw 'Data partition would be smaller than 1 GiB.'
        }
    }
    if ($WindowsMiB -lt ([int64]$MinimumWindowsSizeGiB * 1024)) {
        throw "Planned Windows partition is under $MinimumWindowsSizeGiB GiB."
    }
    return [pscustomobject]@{
        FirmwareMode = $FirmwareMode
        EfiMiB = $ActualEfiMiB
        BiosSystemMiB = $ActualBiosSystemMiB
        MsrMiB = $ReservedMiB
        WindowsMiB = $WindowsMiB
        RecoveryMiB = $RecoveryMiB
        DataMiB = $DataMiB
        AlignmentReserveMiB = $AlignmentReserveMiB
    }
}

function New-OSDDiskPartCommands {
    param(
        [Parameter(Mandatory)][int] $DiskNumber,
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)][string] $RecoveryGuid
    )

    $Commands = @("select disk $DiskNumber", 'clean')
    if ($Plan.FirmwareMode -eq 'UEFI') {
        $Commands += 'convert gpt'
        $Commands += "create partition efi size=$($Plan.EfiMiB)"
        $Commands += 'format quick fs=fat32 label=System'
        $Commands += "create partition msr size=$($Plan.MsrMiB)"
    }
    elseif ($Plan.FirmwareMode -eq 'BIOS') {
        $Commands += 'convert mbr'
        $Commands += "create partition primary size=$($Plan.BiosSystemMiB)"
        $Commands += 'format quick fs=ntfs label="System Reserved"'
        $Commands += 'assign letter=S'
        $Commands += 'active'
    }
    else {
        throw 'Unrecognized partition plan firmware mode.'
    }
    $Commands += "create partition primary size=$($Plan.WindowsMiB)"
    $Commands += 'format quick fs=ntfs label=Windows'
    $Commands += 'assign letter=W'
    $Commands += "create partition primary size=$($Plan.RecoveryMiB)"
    $Commands += 'format quick fs=ntfs label=Recovery'
    if ($Plan.FirmwareMode -eq 'UEFI') {
        $Commands += "set id=$RecoveryGuid"
        $Commands += 'gpt attributes=0x8000000000000001'
    }
    else {
        $Commands += 'set id=27'
    }
    $Commands += 'detail partition'
    if ($Plan.DataMiB -gt 0) {
        $Commands += "create partition primary size=$($Plan.DataMiB)"
        $Commands += 'format quick fs=ntfs label=Data'
    }
    $Commands += 'exit'
    return $Commands
}

function Assert-OSDPartitionStructure {
    param(
        [Parameter(Mandatory)][object[]] $Parts,
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)][string] $RecoveryGuid
    )

    $FirmwareMode = $Plan.FirmwareMode
    $WindowsIndex = if ($FirmwareMode -eq 'UEFI') { 2 } else { 1 }
    $RecoveryIndex = $WindowsIndex + 1
    $DataIndex = $RecoveryIndex + 1
    $ExpectedCount = $RecoveryIndex + 1
    if ($Plan.DataMiB -gt 0) { $ExpectedCount++ }
    if ($Parts.Count -ne $ExpectedCount) {
        throw "Expected $ExpectedCount new partitions."
    }

    if ($FirmwareMode -eq 'UEFI') {
        $ExpectedTypes = @(
            'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
            'e3c9e316-0b5c-4db8-817d-f92df00215ae'
            'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
            $RecoveryGuid
        )
        if ($Plan.DataMiB -gt 0) {
            $ExpectedTypes += 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
        }
        for ($i = 0; $i -lt $ExpectedTypes.Count; $i++) {
            if (([string]$Parts[$i].GptType).Trim('{}') -ine $ExpectedTypes[$i]) {
                throw "Unexpected GPT type or order at partition $($i + 1)."
            }
        }
        if ($Parts[1].Size -ne ([uint64]$Plan.MsrMiB * 1MB) -or
            -not $Parts[$RecoveryIndex].NoDefaultDriveLetter) {
            throw 'GPT MSR size or Recovery attribute verification failed.'
        }
    }
    elseif ($FirmwareMode -eq 'BIOS') {
        $ExpectedTypes = @(7, 7, 39)
        if ($Plan.DataMiB -gt 0) { $ExpectedTypes += 7 }
        for ($i = 0; $i -lt $ExpectedTypes.Count; $i++) {
            if ([int]$Parts[$i].MbrType -ne $ExpectedTypes[$i]) {
                throw "Unexpected MBR type or order at partition $($i + 1)."
            }
        }
        $ActiveParts = @($Parts | Where-Object { $_.IsActive })
        if ($ActiveParts.Count -ne 1 -or
            $ActiveParts[0].PartitionNumber -ne $Parts[0].PartitionNumber -or
            $Parts[0].DriveLetter -ne 'S') {
            throw 'Only the BIOS system partition may be active; it must be S: in WinPE.'
        }
    }
    else {
        throw 'Unrecognized partition plan firmware mode.'
    }

    $BootMiB = if ($FirmwareMode -eq 'UEFI') {
        $Plan.EfiMiB
    } else {
        $Plan.BiosSystemMiB
    }
    if ($Parts[0].Size -ne ([uint64]$BootMiB * 1MB) -or
        $Parts[$WindowsIndex].Size -ne ([uint64]$Plan.WindowsMiB * 1MB) -or
        $Parts[$RecoveryIndex].Size -ne ([uint64]$Plan.RecoveryMiB * 1MB)) {
        throw 'A partition has an unexpected size.'
    }
    $RecoveryGap = [int64]$Parts[$RecoveryIndex].Offset -
        ([int64]$Parts[$WindowsIndex].Offset + [int64]$Parts[$WindowsIndex].Size)
    if ($RecoveryGap -lt 0 -or $RecoveryGap -gt 1MB) {
        throw 'Recovery is not immediately after Windows.'
    }
    if ($Parts[$WindowsIndex].DriveLetter -ne 'W' -or
        ($FirmwareMode -eq 'UEFI' -and $Parts[$RecoveryIndex].DriveLetter)) {
        throw 'Windows or GPT Recovery drive-letter verification failed.'
    }
    if ($Plan.DataMiB -gt 0) {
        if ($Parts[$DataIndex].Size -ne ([uint64]$Plan.DataMiB * 1MB) -or
            $Parts[$DataIndex].Offset -lt
                ($Parts[$RecoveryIndex].Offset + $Parts[$RecoveryIndex].Size)) {
            throw 'Data partition size or order verification failed.'
        }
        if ($FirmwareMode -eq 'UEFI' -and
            [string]::IsNullOrWhiteSpace([string]$Parts[$DataIndex].Guid)) {
            throw 'Data partition GUID verification failed.'
        }
    }
    return [pscustomobject]@{
        WindowsIndex = $WindowsIndex
        RecoveryIndex = $RecoveryIndex
        DataIndex = $DataIndex
        RecoveryHasLetter = [bool]$Parts[$RecoveryIndex].DriveLetter
    }
}

function Assert-OSDDiskState {
    param(
        [Parameter(Mandatory)] $Current,
        [Parameter(Mandatory)] $Selection
    )
    if (($Current.Size -ne $Selection.SizeBytes) -or
        ([uint32]$Current.LogicalSectorSize -ne $Selection.LogicalSectorSize) -or
        ((ConvertTo-OSDBusType ([string]$Current.BusType)) -ne $Selection.BusType) -or
        ([string]$Current.FriendlyName -ne $Selection.Model)) {
        throw 'Disk identity changed since selection; refusing to erase it.'
    }
    if ($Current.IsOffline -or $Current.IsReadOnly -or $Current.IsClustered -or
        ([string]$Current.HealthStatus -notin @('Healthy', 'Unknown'))) {
        throw 'Selected disk is no longer healthy, writable, or available.'
    }
    if ($Selection.Serial -and
        (([string]$Current.SerialNumber).Trim() -ne $Selection.Serial)) {
        throw 'Disk serial changed since selection; refusing to erase it.'
    }
    if ($Selection.UniqueId -and
        ([string]$Current.UniqueId -ne $Selection.UniqueId)) {
        throw 'Disk unique ID changed since selection; refusing to erase it.'
    }
}

function Test-SameDisk {
    param([Parameter(Mandatory)] $Selection)

    $Current = Get-Disk -Number $Selection.Number -ErrorAction Stop
    Assert-OSDDiskState -Current $Current -Selection $Selection

    if ($Selection.VirtualVerified) {
        $Virtual = @(Get-VirtualDisk -Disk $Current -ErrorAction Stop)
        if ($Virtual.Count -ne 1 -or
            ([string]$Virtual[0].UniqueId -ne $Selection.VirtualId) -or
            ([string]$Virtual[0].HealthStatus -ne 'Healthy')) {
            throw 'Storage Spaces virtual disk identity or health changed.'
        }
        $Mapping = @(Get-Disk -VirtualDisk $Virtual[0] -ErrorAction Stop)
        if ($Mapping.Count -ne 1 -or $Mapping[0].Number -ne $Selection.Number) {
            throw 'Storage Spaces virtual disk mapping changed.'
        }
    }

    $Drive = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
        Where-Object { [int]$_.Index -eq $Selection.Number })
    if ($Selection.WmiFound) {
        if (($Drive.Count -ne 1) -or
            ([string]$Drive[0].PNPDeviceID -ne $Selection.PnpId)) {
            throw 'Disk device identity changed since selection; refusing to erase it.'
        }
        if ([string]$Drive[0].InterfaceType -ne $Selection.WmiInterface -or
            [string]$Drive[0].MediaType -ne $Selection.WmiMedia -or
            [string]$Drive[0].Status -notin @('', 'OK', 'Unknown')) {
            throw 'Disk media, interface, or device health changed since selection.'
        }
    }
    elseif (-not $Selection.VirtualVerified -or $Drive.Count -gt 0) {
        throw 'Disk inventory changed since selection; refusing to erase it.'
    }
}

function Assert-OSDPathOffTargetDisk {
    param(
        [AllowEmptyString()][string] $Path,
        [Parameter(Mandatory)][int] $TargetDiskNumber,
        [Parameter(Mandatory)][string] $Description
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $Expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($Expanded.StartsWith('\\')) {
        if ($Expanded.StartsWith('\\?\') -or
            $Expanded.StartsWith('\\.\')) {
            throw "$Description uses a device path that cannot be mapped safely."
        }
        $Server = ($Expanded.Substring(2) -split '[\\/]', 2)[0]
        if ($Server -in @('', '.', 'localhost', '127.0.0.1',
            '[::1]', [string]$env:COMPUTERNAME)) {
            throw "$Description uses a local network alias that may point to the selected disk."
        }
        return
    }
    if ($Expanded -notmatch '^([A-Za-z]):[\\/]') {
        throw "$Description is not an absolute drive or network path; target safety cannot be checked."
    }
    $Letter = [char]$Matches[1].ToUpperInvariant()
    if ($Letter -eq 'X') { return } # WinPE's RAM drive.

    $Partitions = @(Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue)
    if ($Partitions.Count -gt 1) {
        throw "$Description maps to multiple partitions; refusing to erase a disk."
    }
    if ($Partitions.Count -eq 1) {
        if ($Partitions[0].DiskNumber -eq $TargetDiskNumber) {
            throw "$Description resides on the selected disk; refusing to erase task-sequence content."
        }
        return
    }
    $Drive = Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($Drive) {
        $RemoteRoot = [string]$Drive.DisplayRoot
        if (-not $RemoteRoot.StartsWith('\\')) {
            $RemoteRoot = [string]$Drive.Root
        }
        if ($RemoteRoot.StartsWith('\\')) {
            Assert-OSDPathOffTargetDisk -Path $RemoteRoot `
                -TargetDiskNumber $TargetDiskNumber -Description $Description
            return
        }
    }
    throw "$Description has no verifiable off-target disk or network mapping."
}

function Assert-OSDTaskSequenceSource {
    param(
        [Parameter(Mandatory)] $TaskSequenceEnvironment,
        [AllowEmptyString()][string] $RunningScriptPath,
        [Parameter(Mandatory)][int] $TargetDiskNumber
    )
    Assert-OSDPathOffTargetDisk `
        -Path ([string]$TaskSequenceEnvironment.Value('_SMSTSMDataPath')) `
        -TargetDiskNumber $TargetDiskNumber -Description 'Task-sequence working data'
    Assert-OSDPathOffTargetDisk `
        -Path ([string]$TaskSequenceEnvironment.Value('_SMSTSLogPath')) `
        -TargetDiskNumber $TargetDiskNumber -Description 'Task-sequence logs'
    Assert-OSDPathOffTargetDisk -Path $RunningScriptPath `
        -TargetDiskNumber $TargetDiskNumber -Description 'Running PowerShell script'
}

function Assert-OSDWinPEDriveSafety {
    param(
        [Parameter(Mandatory)][int] $TargetDiskNumber,
        [Parameter(Mandatory)][ValidateSet('UEFI', 'BIOS')]
        [string] $FirmwareMode,
        [string] $SystemRootPath = $env:SystemRoot
    )
    $SystemLetter = [char]$SystemRootPath.Substring(0, 1)
    $SystemPartition = @(Get-Partition -DriveLetter $SystemLetter -ErrorAction SilentlyContinue)
    if (@($SystemPartition | Where-Object { $_.DiskNumber -eq $TargetDiskNumber }).Count -gt 0) {
        throw 'The WinPE system root is on the selected disk; refusing to erase it.'
    }
    $Letters = @('W')
    if ($FirmwareMode -eq 'BIOS') { $Letters += 'S' }
    foreach ($Letter in $Letters) {
        $Existing = @(Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue)
        if (@($Existing | Where-Object { $_.DiskNumber -ne $TargetDiskNumber }).Count -gt 0) {
            throw "$($Letter): belongs to another disk and is unavailable."
        }
        if ((Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue) -and
            $Existing.Count -eq 0) {
            throw "$($Letter): is already in use outside the selected disk."
        }
    }
}

function Get-OSDFirmwareMode {
    param(
        $TaskSequenceEnvironment,
        [bool] $IsPreview,
        [string] $SimulatedFirmware
    )

    $InWinPE = Test-Path -LiteralPath 'HKLM:\System\CurrentControlSet\Control\MiniNT'
    if ($TaskSequenceEnvironment -and
        $TaskSequenceEnvironment.Value('_SMSTSInWinPE') -ieq 'true') {
        $InWinPE = $true
    }
    if (-not $InWinPE) {
        if (-not $IsPreview) {
            throw 'Destructive layout requires an actual WinPE boot.'
        }
        if ($SimulatedFirmware) {
            Write-Host "Full-Windows preview: SIMULATING $SimulatedFirmware; not proof of WinPE boot mode."
            return $SimulatedFirmware
        }
        Write-Host 'Full-Windows preview: assuming UEFI for the plan only; specify -PreviewFirmware BIOS to simulate BIOS.'
        return 'UEFI'
    }

    $WpeUtil = Join-Path $env:SystemRoot 'System32\wpeutil.exe'
    if (-not (Test-Path -LiteralPath $WpeUtil -PathType Leaf)) {
        throw 'WinPE firmware detection requires wpeutil.exe.'
    }
    & $WpeUtil UpdateBootInfo | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'WinPE could not update boot-mode information.'
    }
    $BootInfo = Get-ItemProperty -LiteralPath `
        'HKLM:\System\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop
    $TSUEFI = ''
    if ($TaskSequenceEnvironment) {
        $TSUEFI = [string]$TaskSequenceEnvironment.Value('_SMSTSBootUEFI')
        if (-not $TSUEFI) {
            Write-Host 'ConfigMgr firmware flag absent; using the detected WinPE firmware type.'
        }
    }
    $Mode = Resolve-OSDFirmwareMode -PEFirmwareType ([int]$BootInfo.PEFirmwareType) `
        -TaskSequenceUEFIFlag $TSUEFI -SimulatedFirmware $SimulatedFirmware
    Write-Host "WinPE firmware mode: $Mode"
    return $Mode
}

try {
    try {
        $script:TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
    }
    catch {
        if (-not $Preview) {
            throw 'Destructive mode requires an active ConfigMgr task sequence; use -Preview for standalone inventory.'
        }
    }

    # Clear any values from a prior attempt before making a new selection.
    Set-TSValue -Name 'DiskSelectionStatus' -Value 'Failed'
    Set-TSValue -Name 'DiskLayoutStatus' -Value 'Failed'
    Set-TSValue -Name 'DiskLayoutMode' -Value ''
    Set-TSValue -Name 'DiskPartitionStyle' -Value ''
    Set-TSValue -Name 'DiskDataPartitionGuid' -Value ''
    $ReservedOutputs = @(
        'DiskSelectionStatus', 'DiskLayoutStatus',
        'DiskLayoutMode', 'DiskPartitionStyle',
        'DiskDataPartitionGuid', 'OSDTargetSystemDrive'
    )
    if ($OSPartitionVariable -eq $DiskNumberVariable -or
        $OSPartitionVariable -in $ReservedOutputs -or
        $DiskNumberVariable -in $ReservedOutputs) {
        throw 'Output variable names must be distinct and cannot replace status or ConfigMgr-owned outputs.'
    }
    Set-TSValue -Name $DiskNumberVariable -Value ''
    Set-TSValue -Name $OSPartitionVariable -Value ''

    if ($PreviewFirmware -and -not $Preview) {
        throw '-PreviewFirmware is only valid with -Preview.'
    }
    if (-not $Preview) {
        if ($script:TSEnv.Value('_SMSTSInWinPE') -ine 'true') {
            throw 'Destructive mode requires an active WinPE task sequence.'
        }
        if ($script:TSEnv.Value('OSDMigrateUseHardlinks') -eq 'true') {
            throw 'Hard-link migration is active; this fresh-install script must not erase the disk.'
        }
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:TSEnv.Value('_SMSTSClientCache'))) {
            throw 'A task-sequence client cache is present; refusing to erase its possible host disk.'
        }
        if ($script:TSEnv.Value('_SMSTSMediaType') -eq 'OEMMedia') {
            throw 'OEM media mode is not approved for destructive disk layout.'
        }
        if ($script:TSEnv.Value('_SMSTSLaunchMode') -eq 'HD') {
            throw 'Prestaged hard-disk boot media may reside on the target; refusing to erase it.'
        }
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$script:TSEnv.Value('OSDTargetSystemDrive'))) {
            throw 'The OS target is already set; disk layout must run before Apply Operating System.'
        }
    }
    $FirmwareMode = Get-OSDFirmwareMode -TaskSequenceEnvironment $script:TSEnv `
        -IsPreview ([bool]$Preview) -SimulatedFirmware $PreviewFirmware
    Assert-OSDFirmwarePolicy -FirmwareMode $FirmwareMode `
        -RequireUEFI ([bool]$RequireUEFI) -RequireBIOS ([bool]$RequireBIOS)
    if ($FirmwareMode -eq 'BIOS' -and $PSBoundParameters.ContainsKey('EfiSizeMiB')) {
        throw '-EfiSizeMiB only applies to UEFI/GPT.'
    }
    if ($FirmwareMode -eq 'UEFI' -and $PSBoundParameters.ContainsKey('BiosSystemSizeMiB')) {
        throw '-BiosSystemSizeMiB only applies to BIOS/MBR.'
    }
    Import-Module Storage -ErrorAction Stop

    if ($MaximumTargetSizeGB -gt 0 -and
        $MinimumTargetSizeGB -gt $MaximumTargetSizeGB) {
        throw 'Minimum target size exceeds maximum target size.'
    }
    if ($MinimumDiskSizeGB -gt $MaximumDiskSizeGB) {
        throw 'Minimum disk size exceeds maximum disk size.'
    }

    $TargetSerial = $TargetSerial.Trim()
    $TargetModelRegex = $TargetModelRegex.Trim()
    $TargetComputerModelRegex = $TargetComputerModelRegex.Trim()
    if ($AllowVirtualDisk -and $TargetBusType -ne 'Virtual') {
        throw '-AllowVirtualDisk also requires -TargetBusType Virtual.'
    }
    if ($AllowSurfaceStorageSpaces -and
        ($TargetBusType -ne 'StorageSpaces' -or -not $TargetComputerModelRegex)) {
        throw 'Surface Storage Spaces mode requires -TargetBusType StorageSpaces and a computer-model rule.'
    }
    if ($TargetBusType -eq 'StorageSpaces' -and -not $AllowSurfaceStorageSpaces) {
        throw 'A Storage Spaces target requires -AllowSurfaceStorageSpaces.'
    }

    $Computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $ComputerModel = [string]$Computer.Model
    Write-Host "Computer: $($Computer.Manufacturer) $ComputerModel"
    if ($TargetComputerModelRegex -and
        -not (Test-OSDRegexMatch -Value $ComputerModel `
            -Pattern $TargetComputerModelRegex)) {
        throw 'Computer model did not match the approved model rule.'
    }
    if ($AllowSurfaceStorageSpaces -and
        (([string]$Computer.Manufacturer -notmatch '^Microsoft') -or
         ($ComputerModel -notmatch 'Surface'))) {
        throw 'Storage Spaces exception is restricted to identified Microsoft Surface devices.'
    }

    $AllowedBuses = @('NVMe', 'SATA', 'RAID', 'ATA')
    # SAS/SCSI may also describe attached storage. Require a specific rule.
    if ($TargetBusType -in @('SAS', 'SCSI')) { $AllowedBuses += $TargetBusType }
    if ($AllowVirtualDisk) { $AllowedBuses += 'Virtual' }
    if ($AllowSurfaceStorageSpaces) { $AllowedBuses += 'StorageSpaces' }
    $DeviceDrives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)

    $Disks = @(Get-Disk -ErrorAction Stop)
    if ($Disks.Count -eq 0) { throw 'No disks are visible in WinPE.' }
    $Inventory = foreach ($Disk in $Disks) {
        $Number = [int]$Disk.Number
        $Bus = ConvertTo-OSDBusType ([string]$Disk.BusType)
        $MatchingDrives = @($DeviceDrives | Where-Object { $_.Index -eq $Number })
        $Drive = $null
        if ($MatchingDrives.Count -eq 1) { $Drive = $MatchingDrives[0] }
        $VirtualVerified = $false
        $VirtualId = ''
        if ($Bus -eq 'StorageSpaces' -and $AllowSurfaceStorageSpaces) {
            try {
                $Virtual = @(Get-VirtualDisk -Disk $Disk -ErrorAction Stop)
                if ($Virtual.Count -eq 1 -and
                    [string]$Virtual[0].HealthStatus -eq 'Healthy' -and
                    -not [string]::IsNullOrWhiteSpace([string]$Virtual[0].UniqueId)) {
                    $Mapped = @(Get-Disk -VirtualDisk $Virtual[0] -ErrorAction Stop)
                    if ($Mapped.Count -eq 1 -and $Mapped[0].Number -eq $Number) {
                        $VirtualVerified = $true
                        $VirtualId = [string]$Virtual[0].UniqueId
                    }
                }
            }
            catch {
                Write-Host "Disk $Number : Storage Spaces association unavailable; disk remains ineligible."
            }
        }
        $PnpId = ''
        $WmiInterface = ''
        $WmiMedia = ''
        $WmiStatus = ''
        if ($null -ne $Drive) {
            $PnpId = [string]$Drive.PNPDeviceID
            $WmiInterface = [string]$Drive.InterfaceType
            $WmiMedia = [string]$Drive.MediaType
            $WmiStatus = [string]$Drive.Status
        }

        $Entry = [pscustomobject]@{
            Number = $Number
            Model = [string]$Disk.FriendlyName
            Serial = ([string]$Disk.SerialNumber).Trim()
            UniqueId = [string]$Disk.UniqueId
            PnpId = $PnpId
            WmiFound = ($null -ne $Drive)
            WmiInterface = $WmiInterface
            WmiMedia = $WmiMedia
            WmiStatus = $WmiStatus
            BusType = $Bus
            SizeBytes = [uint64]$Disk.Size
            LogicalSectorSize = [uint32]$Disk.LogicalSectorSize
            HealthStatus = [string]$Disk.HealthStatus
            IsOffline = [bool]$Disk.IsOffline
            IsReadOnly = [bool]$Disk.IsReadOnly
            IsClustered = [bool]$Disk.IsClustered
            VirtualVerified = $VirtualVerified
            VirtualId = $VirtualId
        }
        $Eligibility = Test-OSDDiskEligible -Item $Entry -AllowedBuses $AllowedBuses `
            -MinimumDiskSizeGB $MinimumDiskSizeGB `
            -MaximumDiskSizeGB $MaximumDiskSizeGB `
            -AllowStorageSpacesDisk ([bool]$AllowSurfaceStorageSpaces)
        $Entry | Add-Member -NotePropertyName Eligible -NotePropertyValue $Eligibility.Eligible
        $Entry | Add-Member -NotePropertyName Reasons -NotePropertyValue $Eligibility.Reasons
        $Entry
    }

    foreach ($Item in $Inventory) {
        Write-Host ("Disk {0}: {1}; bus={2}; sizeGiB={3:N1}; sector={4} B; serial='{5}'; eligible={6}; {7}" -f
            $Item.Number, $Item.Model, $Item.BusType,
            ($Item.SizeBytes / 1GB), $Item.LogicalSectorSize,
            $Item.Serial, $Item.Eligible, $Item.Reasons)
    }
    $SpacesDisks = @($Inventory | Where-Object { $_.BusType -eq 'StorageSpaces' })
    if ($SpacesDisks.Count -gt 0 -and -not $AllowSurfaceStorageSpaces) {
        throw 'Storage Spaces is visible; an ordinary disk rule must not target its pool members.'
    }
    if ([string]$Computer.Manufacturer -match '^Microsoft' -and
        $ComputerModel -match 'Surface' -and -not $AllowSurfaceStorageSpaces) {
        $PossiblePoolMembers = @($Disks | Where-Object {
            $_.Size -ge 400GB -and $_.Size -le 600GB -and
            ([string]$_.BusType -in @('NVMe', 'SATA', 'RAID'))
        })
        if ($PossiblePoolMembers.Count -ge 2) {
            throw 'Surface has multiple 512-GB-class disks; verify its Storage Spaces configuration first.'
        }
    }

    $SelectionRules = @{
        Inventory = @($Inventory)
        TargetSerial = $TargetSerial
        TargetModelRegex = $TargetModelRegex
        TargetBusType = $TargetBusType
        MinimumDiskSizeGB = $MinimumDiskSizeGB
        MinimumTargetSizeGB = $MinimumTargetSizeGB
        MaximumTargetSizeGB = $MaximumTargetSizeGB
    }
    $Selected = Select-OSDTargetDisk @SelectionRules
    Assert-OSDFirmwareDiskGeometry -Disk $Selected -FirmwareMode $FirmwareMode `
        -EfiMiB $EfiMiB
    $Plan = New-OSDPartitionPlan -DiskSizeBytes $Selected.SizeBytes `
        -FirmwareMode $FirmwareMode -EfiMiB $EfiMiB `
        -BiosSystemMiB $BiosSystemSizeMiB -MsrMiB $MsrMiB `
        -RecoveryMiB $RecoveryMiB `
        -AlignmentReserveMiB $AlignmentReserveMiB -WindowsSizeGiB $WindowsSizeGiB `
        -MinimumWindowsSizeGiB $MinimumWindowsSizeGiB `
        -CreateDataPartition ([bool]$CreateDataPartition)
    if ($FirmwareMode -eq 'UEFI') {
        Write-Host ("Target Disk {0}; GPT: EFI {1} MiB, MSR {2} MiB, Windows {3} MiB, Recovery {4} MiB, Data {5} MiB." -f
            $Selected.Number, $Plan.EfiMiB, $Plan.MsrMiB, $Plan.WindowsMiB,
            $Plan.RecoveryMiB, $Plan.DataMiB)
    }
    else {
        Write-Host ("Target Disk {0}; MBR: System {1} MiB, Windows {2} MiB, Recovery {3} MiB, Data {4} MiB." -f
            $Selected.Number, $Plan.BiosSystemMiB, $Plan.WindowsMiB,
            $Plan.RecoveryMiB, $Plan.DataMiB)
    }

    if ($Preview) {
        Test-SameDisk -Selection $Selected
        $PreviewCommands = @(New-OSDDiskPartCommands -DiskNumber $Selected.Number `
            -Plan $Plan -RecoveryGuid $RecoveryGuid)
        Write-Host 'PREVIEW ONLY: the following commands would be generated, NOT executed:'
        foreach ($Command in $PreviewCommands) { Write-Host "  $Command" }
        $EnvironmentName = 'Standalone Windows or WinPE; not an active task sequence'
        if ($script:TSEnv) {
            if ($script:TSEnv.Value('_SMSTSInWinPE') -eq 'true') {
                $EnvironmentName = 'Active task sequence in WinPE'
            }
            else {
                $EnvironmentName = 'Active task sequence in full Windows'
            }
        }
        Write-Host "Preview environment: $EnvironmentName"
        Write-Host 'Full-Windows disk inventory can differ from the ConfigMgr WinPE boot image.'
        if ($script:TSEnv) {
            if ($script:TSEnv.Value('_SMSTSInWinPE') -ieq 'true') {
                Assert-OSDTaskSequenceSource -TaskSequenceEnvironment $script:TSEnv `
                    -RunningScriptPath ([string]$PSCommandPath) `
                    -TargetDiskNumber $Selected.Number
                Assert-OSDWinPEDriveSafety -TargetDiskNumber $Selected.Number `
                    -FirmwareMode $FirmwareMode
            }
            throw 'Preview only: task sequence stopped before formatting.'
        }
        Write-Host 'No disk was modified.'
        exit 0
    }

    Test-SameDisk -Selection $Selected
    Assert-OSDTaskSequenceSource -TaskSequenceEnvironment $script:TSEnv `
        -RunningScriptPath ([string]$PSCommandPath) `
        -TargetDiskNumber $Selected.Number
    Assert-OSDWinPEDriveSafety -TargetDiskNumber $Selected.Number `
        -FirmwareMode $FirmwareMode

    $WorkRoot = Join-Path $env:SystemRoot 'Temp'
    if (-not (Test-Path -LiteralPath $WorkRoot -PathType Container)) {
        throw 'The WinPE temporary folder is unavailable.'
    }
    $DiskPartPath = Join-Path $env:SystemRoot 'System32\diskpart.exe'
    if (-not (Test-Path -LiteralPath $DiskPartPath -PathType Leaf)) {
        throw 'DiskPart is unavailable in the WinPE boot image.'
    }

    # One DiskPart process: no hard-coded disk number and no second formatting
    # step. Extra alignment space is intentionally left after Recovery.
    [string[]]$Commands = @(New-OSDDiskPartCommands -DiskNumber $Selected.Number `
        -Plan $Plan -RecoveryGuid $RecoveryGuid)
    $PlanPath = Join-Path $WorkRoot ('OSD-Partition-' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllLines($PlanPath, $Commands,
        (New-Object System.Text.ASCIIEncoding))

    # Recheck immediately before the first destructive command.
    Test-SameDisk -Selection $Selected
    Write-Host "ERASING Disk $($Selected.Number): $($Selected.Model); serial=$($Selected.Serial)"
    $Output = & $DiskPartPath /s $PlanPath 2>&1
    $DiskPartExitCode = $LASTEXITCODE
    foreach ($Line in $Output) { Write-Host ([string]$Line) }
    if ($DiskPartExitCode -ne 0) {
        throw "Partitioning failed; DiskPart returned $DiskPartExitCode. Do not continue the task sequence."
    }

    $ExpectedStyle = if ($FirmwareMode -eq 'UEFI') { 'GPT' } else { 'MBR' }
    $WindowsIndex = if ($FirmwareMode -eq 'UEFI') { 2 } else { 1 }
    $RecoveryIndex = $WindowsIndex + 1
    $DataIndex = $RecoveryIndex + 1
    $ExpectedCount = $RecoveryIndex + 1
    if ($Plan.DataMiB -gt 0) { $ExpectedCount++ }

    # Storage WMI may lag DiskPart briefly. Retry only read-only inspection,
    # never the destructive command sequence.
    $ResultDisk = $null
    $Parts = @()
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            $ResultDisk = Get-Disk -Number $Selected.Number -ErrorAction Stop
            $Parts = @(Get-Partition -DiskNumber $Selected.Number -ErrorAction Stop |
                Sort-Object Offset)
            if ($ResultDisk.PartitionStyle -eq $ExpectedStyle -and
                $Parts.Count -eq $ExpectedCount) {
                break
            }
        }
        catch {
            if ($Attempt -eq 3) { throw }
        }
        if ($Attempt -lt 3) {
            Start-Sleep -Seconds 2
        }
    }
    if (($ResultDisk.PartitionStyle -ne $ExpectedStyle) -or
        ($ResultDisk.Size -ne $Selected.SizeBytes) -or
        ($Selected.Serial -and
         (([string]$ResultDisk.SerialNumber).Trim() -ne $Selected.Serial))) {
        throw 'Post-format disk identity or partition-style verification failed.'
    }
    $PostDevice = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
        Where-Object { $_.Index -eq $Selected.Number })
    if ($Selected.WmiFound -and
        ($PostDevice.Count -ne 1 -or
         [string]$PostDevice[0].PNPDeviceID -ne $Selected.PnpId)) {
        throw 'Post-format device identity verification failed.'
    }
    if ($Selected.VirtualVerified) {
        $PostVirtual = @(Get-VirtualDisk -Disk $ResultDisk -ErrorAction Stop)
        if ($PostVirtual.Count -ne 1 -or
            [string]$PostVirtual[0].UniqueId -ne $Selected.VirtualId) {
            throw 'Post-format Storage Spaces association changed.'
        }
    }
    $Layout = Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
        -RecoveryGuid $RecoveryGuid
    $WindowsIndex = $Layout.WindowsIndex
    $RecoveryIndex = $Layout.RecoveryIndex
    $DataIndex = $Layout.DataIndex
    if ($FirmwareMode -eq 'BIOS' -and $Layout.RecoveryHasLetter) {
        Write-Host 'MBR Recovery has a temporary WinPE letter; verify it is hidden after first boot.'
    }
    $WindowsVolume = Get-Volume -DriveLetter W -ErrorAction Stop
    $SystemVolume = Get-Volume -Partition $Parts[0] -ErrorAction Stop
    $ExpectedSystemFS = if ($FirmwareMode -eq 'UEFI') { 'FAT32' } else { 'NTFS' }
    if ($WindowsVolume.FileSystem -ne 'NTFS' -or
        $SystemVolume.FileSystem -ne $ExpectedSystemFS) {
        throw 'Windows or system-partition filesystem verification failed.'
    }
    $RecoveryVolume = @(Get-Volume -Partition $Parts[$RecoveryIndex] -ErrorAction SilentlyContinue)
    if ($RecoveryVolume.Count -gt 1 -or
        ($RecoveryVolume.Count -eq 1 -and $RecoveryVolume[0].FileSystem -ne 'NTFS')) {
        throw 'Recovery NTFS verification failed.'
    }
    if ($RecoveryVolume.Count -eq 0) {
        Write-Host 'Recovery filesystem is not exposed in WinPE; validate it after Windows setup.'
    }
    if ($Plan.DataMiB -gt 0) {
        $DataVolume = Get-Volume -Partition $Parts[$DataIndex] -ErrorAction Stop
        if ($DataVolume.FileSystem -ne 'NTFS') {
            throw 'Data partition filesystem verification failed.'
        }
    }

    Set-TSValue -Name $DiskNumberVariable -Value ([string]$Selected.Number)
    Set-TSValue -Name $OSPartitionVariable -Value 'W:'
    if ($Plan.DataMiB -gt 0 -and $FirmwareMode -eq 'UEFI') {
        Set-TSValue -Name 'DiskDataPartitionGuid' -Value ([string]$Parts[$DataIndex].Guid)
    }
    Set-TSValue -Name 'DiskLayoutMode' -Value 'FreshInstall'
    Set-TSValue -Name 'DiskPartitionStyle' -Value $ExpectedStyle
    Set-TSValue -Name 'DiskSelectionStatus' -Value 'Success'
    Set-TSValue -Name 'DiskLayoutStatus' -Value 'Success'
    Write-Host "SUCCESS: $ExpectedStyle layout verified; $OSPartitionVariable=W:. Check boot and WinRE after setup."
    exit 0
}
catch {
    $Failure = $_.Exception.Message
    if ($script:TSEnv) {
        try {
            Set-TSValue -Name $DiskNumberVariable -Value ''
            Set-TSValue -Name $OSPartitionVariable -Value ''
            Set-TSValue -Name 'DiskDataPartitionGuid' -Value ''
            Set-TSValue -Name 'DiskLayoutMode' -Value ''
            Set-TSValue -Name 'DiskPartitionStyle' -Value ''
            Set-TSValue -Name 'DiskSelectionStatus' -Value 'Failed'
            Set-TSValue -Name 'DiskLayoutStatus' -Value 'Failed'
        }
        catch {
            Write-Verbose 'Unable to update failure status variables during cleanup.'
        }
    }
    Write-Host "STOPPED: $Failure"
    exit 1
}
finally {
    if ($PlanPath -and (Test-Path -LiteralPath $PlanPath)) {
        Remove-Item -LiteralPath $PlanPath -Force -ErrorAction SilentlyContinue
    }
}
