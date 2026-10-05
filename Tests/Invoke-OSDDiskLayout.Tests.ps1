#Requires -Version 5.1
# Requires Pester 5. These tests import ONLY pure functions from the script AST;
# they do not run the script entry point or invoke DiskPart.

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot '..\Invoke-OSDDiskLayout.ps1'
    $Tokens = $null
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count -gt 0) {
        throw ($Errors | ForEach-Object Message | Out-String)
    }

    foreach ($Name in @(
        'ConvertTo-OSDBusType',
        'Test-OSDRegexMatch',
        'ConvertFrom-PEFirmwareType',
        'Resolve-OSDFirmwareMode',
        'Assert-OSDFirmwarePolicy',
        'Test-OSDDiskEligible',
        'Select-OSDTargetDisk',
        'Assert-OSDFirmwareDiskGeometry',
        'Assert-OSDDiskState',
        'New-OSDPartitionPlan',
        'New-OSDDiskPartCommands',
        'Assert-OSDPartitionStructure',
        'Assert-OSDPathOffTargetDisk',
        'Assert-OSDWinPEDriveSafety'
    )) {
        $Functions = @($Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -eq $Name
        }, $true))
        if ($Functions.Count -ne 1) { throw "Expected one definition of $Name." }
        . ([scriptblock]::Create($Functions[0].Extent.Text))
    }

    function New-FixtureDisk {
        param(
            [int] $Number,
            [string] $BusType = 'NVMe',
            [string] $Serial = '',
            [string] $UniqueId = '',
            [uint64] $SizeBytes = 128GB,
            [uint32] $LogicalSectorSize = 512,
            [bool] $Eligible = $true,
            [string] $Reasons = '',
            [bool] $WmiFound = $true,
            [string] $WmiInterface = 'SCSI',
            [string] $WmiMedia = 'Fixed hard disk media',
            [string] $PnpId = 'SCSI\DISK&VEN_TEST',
            [string] $WmiStatus = 'OK',
            [bool] $VirtualVerified = $false,
            [string] $VirtualId = '',
            [string] $HealthStatus = 'Healthy'
        )
        return [pscustomobject]@{
            Number = $Number
            BusType = $BusType
            Model = 'Approved SSD'
            Serial = $Serial
            UniqueId = $UniqueId
            SizeBytes = $SizeBytes
            LogicalSectorSize = $LogicalSectorSize
            Eligible = $Eligible
            Reasons = $Reasons
            WmiFound = $WmiFound
            WmiInterface = $WmiInterface
            WmiMedia = $WmiMedia
            PnpId = $PnpId
            WmiStatus = $WmiStatus
            VirtualVerified = $VirtualVerified
            VirtualId = $VirtualId
            HealthStatus = $HealthStatus
            IsOffline = $false
            IsReadOnly = $false
            IsClustered = $false
        }
    }

    function New-FixturePartitionLayout {
        param([Parameter(Mandatory)] $Plan)

        $Sizes = @()
        $GptTypes = @()
        $MbrTypes = @()
        if ($Plan.FirmwareMode -eq 'UEFI') {
            $Sizes = @($Plan.EfiMiB, $Plan.MsrMiB,
                $Plan.WindowsMiB, $Plan.RecoveryMiB)
            $GptTypes = @(
                'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
                'e3c9e316-0b5c-4db8-817d-f92df00215ae'
                'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
                'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
            )
            $WindowsIndex = 2
        }
        else {
            $Sizes = @($Plan.BiosSystemMiB,
                $Plan.WindowsMiB, $Plan.RecoveryMiB)
            $MbrTypes = @(7, 7, 39)
            $WindowsIndex = 1
        }
        $RecoveryIndex = $WindowsIndex + 1
        if ($Plan.DataMiB -gt 0) {
            $Sizes += $Plan.DataMiB
            if ($Plan.FirmwareMode -eq 'UEFI') {
                $GptTypes += 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
            }
            else { $MbrTypes += 7 }
        }
        $Offset = [uint64]1MB
        $Parts = for ($i = 0; $i -lt $Sizes.Count; $i++) {
            $Size = [uint64]$Sizes[$i] * 1MB
            $GptType = ''
            $MbrType = 0
            $DriveLetter = ''
            $Guid = ''
            if ($Plan.FirmwareMode -eq 'UEFI') {
                $GptType = $GptTypes[$i]
                if ($Plan.DataMiB -gt 0 -and $i -eq ($Sizes.Count - 1)) {
                    $Guid = '11111111-1111-1111-1111-111111111111'
                }
            }
            else {
                $MbrType = $MbrTypes[$i]
                if ($i -eq 0) { $DriveLetter = 'S' }
            }
            if ($i -eq $WindowsIndex) { $DriveLetter = 'W' }
            [pscustomobject]@{
                PartitionNumber = $i + 1
                Offset = $Offset
                Size = $Size
                GptType = $GptType
                MbrType = $MbrType
                IsActive = ($Plan.FirmwareMode -eq 'BIOS' -and $i -eq 0)
                DriveLetter = $DriveLetter
                NoDefaultDriveLetter = ($Plan.FirmwareMode -eq 'UEFI' -and
                    $i -eq $RecoveryIndex)
                Guid = $Guid
            }
            $Offset += $Size
        }
        return @($Parts)
    }
}

Describe 'Firmware detection decision (no hardware writes)' {
    It 'maps the documented WinPE values to BIOS and UEFI' {
        ConvertFrom-PEFirmwareType 1 | Should -Be 'BIOS'
        ConvertFrom-PEFirmwareType 2 | Should -Be 'UEFI'
        { ConvertFrom-PEFirmwareType 0 } | Should -Throw
        { ConvertFrom-PEFirmwareType 3 } | Should -Throw
    }

    It 'allows a missing ConfigMgr firmware flag but not a contradictory one' {
        Resolve-OSDFirmwareMode -PEFirmwareType 1 | Should -Be 'BIOS'
        Resolve-OSDFirmwareMode -PEFirmwareType 2 -TaskSequenceUEFIFlag true |
            Should -Be 'UEFI'
        { Resolve-OSDFirmwareMode -PEFirmwareType 1 `
            -TaskSequenceUEFIFlag true } | Should -Throw
        { Resolve-OSDFirmwareMode -PEFirmwareType 2 `
            -TaskSequenceUEFIFlag false } | Should -Throw
        { Resolve-OSDFirmwareMode -PEFirmwareType 2 `
            -TaskSequenceUEFIFlag unknown } | Should -Throw
    }

    It 'does not allow preview to override actual WinPE boot mode' {
        { Resolve-OSDFirmwareMode -PEFirmwareType 1 `
            -SimulatedFirmware UEFI } | Should -Throw
        Resolve-OSDFirmwareMode -PEFirmwareType 1 -SimulatedFirmware BIOS |
            Should -Be 'BIOS'
    }

    It 'can require a matching boot mode for a specific OS image' {
        { Assert-OSDFirmwarePolicy -FirmwareMode BIOS -RequireUEFI $true } |
            Should -Throw
        { Assert-OSDFirmwarePolicy -FirmwareMode UEFI -RequireBIOS $true } |
            Should -Throw
        { Assert-OSDFirmwarePolicy -FirmwareMode BIOS -RequireBIOS $true } |
            Should -Not -Throw
        { Assert-OSDFirmwarePolicy -FirmwareMode UEFI -RequireUEFI $true } |
            Should -Not -Throw
        { Assert-OSDFirmwarePolicy -FirmwareMode BIOS `
            -RequireUEFI $true -RequireBIOS $true } | Should -Throw
    }
}

Describe 'Bounded approved matching' {
    It 'matches disk models without case sensitivity' {
        Test-OSDRegexMatch -Value 'Approved SSD' -Pattern '^approved' |
            Should -BeTrue
        Test-OSDRegexMatch -Value 'Another SSD' -Pattern '^approved' |
            Should -BeFalse
    }

    It 'rejects a malformed model rule before a disk can be changed' {
        { Test-OSDRegexMatch -Value 'Approved SSD' -Pattern '[' } |
            Should -Throw
    }
}

Describe 'Disk eligibility (no hardware writes)' {
    It 'normalizes Storage Spaces bus labels' {
        ConvertTo-OSDBusType 'Storage Spaces' | Should -Be 'StorageSpaces'
        ConvertTo-OSDBusType 'Spaces' | Should -Be 'StorageSpaces'
    }

    It 'rejects USB even when device metadata says fixed media' {
        $Disk = New-FixtureDisk -Number 0 -BusType USB -Serial 'USB1'
        $Result = Test-OSDDiskEligible -Item $Disk `
            -AllowedBuses @('NVMe', 'SATA') -MinimumDiskSizeGB 64
        $Result.Eligible | Should -BeFalse
    }

    It 'rejects USB-C/UASP reported on an approved SCSI bus' {
        $Disk = New-FixtureDisk -Number 1 -BusType SCSI -Serial 'UASP1' `
            -PnpId 'UASPSTOR\DISK&VEN_TEST'
        $Result = Test-OSDDiskEligible -Item $Disk `
            -AllowedBuses @('SCSI') -MinimumDiskSizeGB 64
        $Result.Eligible | Should -BeFalse
    }

    It 'rejects missing device inventory for an ordinary NVMe target' {
        $Disk = New-FixtureDisk -Number 2 -Serial 'NV1' -WmiFound $false
        $Result = Test-OSDDiskEligible -Item $Disk `
            -AllowedBuses @('NVMe') -MinimumDiskSizeGB 64
        $Result.Eligible | Should -BeFalse
    }

    It 'uses decimal GB for capacity policy while keeping MiB for layout' {
        $Disk = New-FixtureDisk -Number 2 -Serial 'SSD64' `
            -SizeBytes ([uint64]64000000000)
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('NVMe') `
            -MinimumDiskSizeGB 64).Eligible | Should -BeTrue
        $Disk.SizeBytes = [uint64]63999999999
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('NVMe') `
            -MinimumDiskSizeGB 64).Eligible | Should -BeFalse
        (New-OSDPartitionPlan -DiskSizeBytes ([uint64]64000000000)).WindowsMiB |
            Should -BeGreaterThan 40960
    }

    It 'accepts only an explicitly verified healthy Storage Spaces virtual disk' {
        $Disk = New-FixtureDisk -Number 3 -BusType StorageSpaces `
            -Serial '' -UniqueId '' -WmiFound $false `
            -VirtualVerified $true -VirtualId 'VD-1'
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('StorageSpaces') `
            -MinimumDiskSizeGB 64 -AllowStorageSpacesDisk $true).Eligible |
            Should -BeTrue
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('StorageSpaces') `
            -MinimumDiskSizeGB 64 -AllowStorageSpacesDisk $false).Eligible |
            Should -BeFalse
        $Disk.HealthStatus = 'Warning'
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('StorageSpaces') `
            -MinimumDiskSizeGB 64 -AllowStorageSpacesDisk $true).Eligible |
            Should -BeFalse
    }
}

Describe 'Fail-closed target selection' {
    It 'selects a unique internal Disk 2 while ignoring USB Disk 0' {
        $Usb = New-FixtureDisk -Number 0 -BusType USB -Serial 'USB1' `
            -Eligible $false -Reasons 'unapproved bus USB'
        $Internal = New-FixtureDisk -Number 2 -Serial 'OS2'
        $Chosen = Select-OSDTargetDisk -Inventory @($Usb, $Internal)
        $Chosen.Number | Should -Be 2
    }

    It 'does not require disk numbers to be consecutive' {
        $Usb = New-FixtureDisk -Number 0 -BusType USB -Serial 'USB0' `
            -Eligible $false -Reasons 'unapproved bus USB'
        $Internal = New-FixtureDisk -Number 3 -Serial 'OS3'
        (Select-OSDTargetDisk -Inventory @($Usb, $Internal)).Number |
            Should -Be 3
    }

    It 'stops when only USB media is visible' {
        $Usb = New-FixtureDisk -Number 0 -BusType USB -Serial 'USB1' `
            -Eligible $false -Reasons 'unapproved bus USB'
        { Select-OSDTargetDisk -Inventory @($Usb) } |
            Should -Throw
    }

    It 'fails rather than guessing between two internal disks' {
        $Disks = @(
            (New-FixtureDisk -Number 0 -Serial 'DATA0')
            (New-FixtureDisk -Number 2 -Serial 'OS2')
        )
        { Select-OSDTargetDisk -Inventory $Disks } |
            Should -Throw
        { Select-OSDTargetDisk -Inventory $Disks -MinimumTargetSizeGB 64 } |
            Should -Throw
    }

    It 'applies an explicit serial rule even if only one disk remains' {
        $Disk = New-FixtureDisk -Number 0 -Serial 'DATA0'
        { Select-OSDTargetDisk -Inventory @($Disk) -TargetSerial 'MISSING2' } |
            Should -Throw
    }

    It 'selects the unique approved target in a multi-disk inventory' {
        $Disks = @(
            (New-FixtureDisk -Number 0 -Serial 'DATA0')
            (New-FixtureDisk -Number 2 -Serial 'OS2')
        )
        (Select-OSDTargetDisk -Inventory $Disks -TargetSerial 'OS2').Number |
            Should -Be 2
    }

    It 'stops if a second potentially internal disk is present but ineligible' {
        $Disks = @(
            (New-FixtureDisk -Number 0 -Serial 'DATA0')
            (New-FixtureDisk -Number 2 -BusType Unknown -Serial 'OS2' `
                -Eligible $false -Reasons 'unapproved bus')
        )
        { Select-OSDTargetDisk -Inventory $Disks } |
            Should -Throw
    }

    It 'does not mistake one pool member for a sole OS disk' {
        $Disks = @(
            (New-FixtureDisk -Number 0 -Serial 'POOL0')
            (New-FixtureDisk -Number 2 -BusType StorageSpaces -Serial '' `
                -Eligible $false -Reasons 'virtual disk not verified')
        )
        { Select-OSDTargetDisk -Inventory $Disks } |
            Should -Throw
    }

    It 'stops if a serial is duplicated in the inventory' {
        $Disks = @(
            (New-FixtureDisk -Number 0 -Serial 'DUPLICATE')
            (New-FixtureDisk -Number 1 -Serial 'DUPLICATE' -Eligible $false)
        )
        { Select-OSDTargetDisk -Inventory $Disks -TargetSerial 'DUPLICATE' } |
            Should -Throw
    }

    It 'does not trust a disk UniqueId alone across a clean operation' {
        $Disk = New-FixtureDisk -Number 2 -Serial '' -UniqueId 'OLD-GPT-ID' `
            -PnpId ''
        { Select-OSDTargetDisk -Inventory @($Disk) } | Should -Throw
    }

    It 'accepts a unique persistent PnP identity when serial is unavailable' {
        $Disk = New-FixtureDisk -Number 2 -Serial '' -UniqueId '' `
            -PnpId 'NVME\APPROVED_SERIAL'
        (Select-OSDTargetDisk -Inventory @($Disk)).Number | Should -Be 2
    }

    It 'can target a uniquely identified Surface virtual disk 3 without a serial' {
        $Disks = @(
            (New-FixtureDisk -Number 0 -Serial 'POOL0')
            (New-FixtureDisk -Number 1 -Serial 'POOL1')
            (New-FixtureDisk -Number 2 -BusType SD -Serial 'CARD' -Eligible $false)
            (New-FixtureDisk -Number 3 -BusType StorageSpaces -Serial '' `
                -UniqueId '' -VirtualVerified $true -VirtualId 'SURFACE-SPACE')
        )
        (Select-OSDTargetDisk -Inventory $Disks -TargetBusType StorageSpaces).Number |
            Should -Be 3
    }
}

Describe 'Final disk recheck (no hardware writes)' {
    It 'accepts an unchanged, healthy, writable disk' {
        $Selected = New-FixtureDisk -Number 3 -Serial 'APPROVED'
        $Current = [pscustomobject]@{
            Size = $Selected.SizeBytes
            LogicalSectorSize = 512
            BusType = 'NVMe'
            FriendlyName = $Selected.Model
            SerialNumber = 'APPROVED'
            UniqueId = ''
            HealthStatus = 'Healthy'
            IsOffline = $false
            IsReadOnly = $false
            IsClustered = $false
        }
        { Assert-OSDDiskState -Current $Current -Selection $Selected } |
            Should -Not -Throw
    }

    It 'stops if disk health, write protection, size, or geometry changes' {
        $Selected = New-FixtureDisk -Number 3 -Serial 'APPROVED'
        $Current = [pscustomobject]@{
            Size = $Selected.SizeBytes
            LogicalSectorSize = 512
            BusType = 'NVMe'
            FriendlyName = $Selected.Model
            SerialNumber = 'APPROVED'
            UniqueId = ''
            HealthStatus = 'Healthy'
            IsOffline = $false
            IsReadOnly = $false
            IsClustered = $false
        }
        $Current.IsReadOnly = $true
        { Assert-OSDDiskState -Current $Current -Selection $Selected } |
            Should -Throw
        $Current.IsReadOnly = $false
        $Current.HealthStatus = 'Warning'
        { Assert-OSDDiskState -Current $Current -Selection $Selected } |
            Should -Throw
        $Current.HealthStatus = 'Healthy'
        $Current.Size = $Selected.SizeBytes + 1
        { Assert-OSDDiskState -Current $Current -Selection $Selected } |
            Should -Throw
        $Current.Size = $Selected.SizeBytes
        $Current.LogicalSectorSize = 4096
        { Assert-OSDDiskState -Current $Current -Selection $Selected } |
            Should -Throw
    }
}

Describe 'Partition calculation and DiskPart plan' {
    It 'reserves the exact recovery size after a dynamic Windows partition' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 128GB
        $Plan.EfiMiB | Should -Be 1024
        $Plan.MsrMiB | Should -Be 16
        $Plan.WindowsMiB | Should -Be 127952
        $Plan.RecoveryMiB | Should -Be 2048
        $Plan.DataMiB | Should -Be 0
        $Plan.AlignmentReserveMiB | Should -Be 32
    }

    It 'rejects a disk too small for a usable Windows partition' {
        { New-OSDPartitionPlan -DiskSizeBytes 32GB } | Should -Throw
    }

    It 'can plan a smaller legacy disk only with explicit lower limits' {
        $Disk = New-FixtureDisk -Number 3 -Serial 'SMALL' `
            -SizeBytes ([uint64]32000000000)
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('ATA') `
            -MinimumDiskSizeGB 32).Eligible | Should -BeFalse
        $Disk.BusType = 'ATA'
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('ATA') `
            -MinimumDiskSizeGB 64).Eligible | Should -BeFalse
        (Test-OSDDiskEligible -Item $Disk -AllowedBuses @('ATA') `
            -MinimumDiskSizeGB 32).Eligible | Should -BeTrue
        { New-OSDPartitionPlan -DiskSizeBytes $Disk.SizeBytes -FirmwareMode BIOS } |
            Should -Throw
        $Plan = New-OSDPartitionPlan -DiskSizeBytes $Disk.SizeBytes `
            -FirmwareMode BIOS -MinimumWindowsSizeGiB 24
        $Plan.WindowsMiB | Should -BeGreaterThan (24 * 1024)
    }

    It 'recalculates Windows when EFI and Recovery sizes change' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 256GB `
            -EfiMiB 512 -RecoveryMiB 4096
        $Plan.WindowsMiB | Should -Be (256 * 1024 - 512 - 16 - 4096 - 32)
        $Plan.RecoveryMiB | Should -Be 4096
    }

    It 'requires both a fixed OS size and the explicit Data switch' {
        { New-OSDPartitionPlan -DiskSizeBytes 256GB -WindowsSizeGiB 120 } |
            Should -Throw
        { New-OSDPartitionPlan -DiskSizeBytes 256GB -CreateDataPartition $true } |
            Should -Throw
    }

    It 'rejects a fixed OS partition that leaves too little room for Data' {
        { New-OSDPartitionPlan -DiskSizeBytes 128GB `
            -WindowsSizeGiB 127 -CreateDataPartition $true } |
            Should -Throw
    }

    It 'places an optional Data partition after Recovery' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 256GB `
            -WindowsSizeGiB 120 -CreateDataPartition $true
        $Plan.WindowsMiB | Should -Be 122880
        $Plan.DataMiB | Should -Be (256 * 1024 - 1024 - 16 - 2048 - 32 - 122880)
        $Lines = @(New-OSDDiskPartCommands -DiskNumber 2 -Plan $Plan `
            -RecoveryGuid 'de94bba4-06d1-4d40-a16a-bfd50179d6ac')
        $Lines[9] | Should -Be 'create partition primary size=2048'
        $Lines[14] | Should -Be "create partition primary size=$($Plan.DataMiB)"
        $Lines[15] | Should -Be 'format quick fs=ntfs label=Data'
        $Lines[-1] | Should -Be 'exit'
    }

    It 'uses the selected disk and orders Recovery last, with no noerr' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 128GB
        $Lines = @(New-OSDDiskPartCommands -DiskNumber 3 -Plan $Plan `
            -RecoveryGuid 'de94bba4-06d1-4d40-a16a-bfd50179d6ac')
        $Lines[0] | Should -Be 'select disk 3'
        $Lines[6] | Should -Be 'create partition primary size=127952'
        $Lines[9] | Should -Be 'create partition primary size=2048'
        $Lines[12] | Should -Be 'gpt attributes=0x8000000000000001'
        $Lines[-1] | Should -Be 'exit'
        ($Lines -join ';') | Should -Not -Match 'noerr|clean all|select disk 0'
        @($Lines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count |
            Should -Be 0
    }

    It 'uses active MBR System, Windows, then type-27 Recovery in BIOS mode' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 128GB -FirmwareMode BIOS
        $Plan.FirmwareMode | Should -Be 'BIOS'
        $Plan.EfiMiB | Should -Be 0
        $Plan.MsrMiB | Should -Be 0
        $Plan.BiosSystemMiB | Should -Be 512
        $Plan.WindowsMiB | Should -Be 128480
        $Plan.RecoveryMiB | Should -Be 2048
        $Lines = @(New-OSDDiskPartCommands -DiskNumber 3 -Plan $Plan `
            -RecoveryGuid 'de94bba4-06d1-4d40-a16a-bfd50179d6ac')
        $Lines[0] | Should -Be 'select disk 3'
        $Lines[2] | Should -Be 'convert mbr'
        $Lines[3] | Should -Be 'create partition primary size=512'
        $Lines[4] | Should -Be 'format quick fs=ntfs label="System Reserved"'
        $Lines[5] | Should -Be 'assign letter=S'
        $Lines[6] | Should -Be 'active'
        $Lines[7] | Should -Be 'create partition primary size=128480'
        $Lines[10] | Should -Be 'create partition primary size=2048'
        $Lines[12] | Should -Be 'set id=27'
        $Lines[-1] | Should -Be 'exit'
        ($Lines -join ';') | Should -Not -Match 'convert gpt|create partition efi|noerr|select disk 0'
    }

    It 'allows exactly four primary partitions when BIOS Data is requested' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 256GB -FirmwareMode BIOS `
            -WindowsSizeGiB 120 -CreateDataPartition $true
        $Plan.DataMiB | Should -Be (256 * 1024 - 512 - 2048 - 32 - 122880)
        $Lines = @(New-OSDDiskPartCommands -DiskNumber 2 -Plan $Plan `
            -RecoveryGuid 'de94bba4-06d1-4d40-a16a-bfd50179d6ac')
        @($Lines | Where-Object { $_ -match '^create partition primary' }).Count |
            Should -Be 4
        $Lines[14] | Should -Be "create partition primary size=$($Plan.DataMiB)"
    }

    It 'rejects a BIOS/MBR disk over 2 TB decimal before generating commands' {
        { New-OSDPartitionPlan -DiskSizeBytes ([uint64]2000000000001) `
            -FirmwareMode BIOS } | Should -Throw
        (New-OSDPartitionPlan -DiskSizeBytes ([uint64]2000000000001) `
            -FirmwareMode UEFI).FirmwareMode | Should -Be 'UEFI'
    }

    It 'keeps Recovery adjacent to a resized BIOS Windows partition' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 512GB -FirmwareMode BIOS `
            -BiosSystemMiB 1024 -RecoveryMiB 4096 `
            -WindowsSizeGiB 120 -CreateDataPartition $true
        $Plan.WindowsMiB | Should -Be 122880
        $Plan.BiosSystemMiB | Should -Be 1024
        $Plan.RecoveryMiB | Should -Be 4096
        $Plan.DataMiB | Should -Be (512 * 1024 - 1024 - 4096 - 32 - 122880)
    }

    It 'blocks 4Kn or unknown logical sectors only for BIOS' {
        $FourKn = New-FixtureDisk -Number 3 -Serial '4K1' `
            -LogicalSectorSize 4096
        { Assert-OSDFirmwareDiskGeometry -Disk $FourKn -FirmwareMode BIOS } |
            Should -Throw
        { Assert-OSDFirmwareDiskGeometry -Disk $FourKn -FirmwareMode UEFI } |
            Should -Not -Throw
        $FourKn.LogicalSectorSize = 0
        { Assert-OSDFirmwareDiskGeometry -Disk $FourKn -FirmwareMode BIOS } |
            Should -Throw
        $FourKn.LogicalSectorSize = 512
        { Assert-OSDFirmwareDiskGeometry -Disk $FourKn -FirmwareMode BIOS } |
            Should -Not -Throw
    }

    It 'enforces the current EFI minimum by logical sector size' {
        $Disk = New-FixtureDisk -Number 3 -Serial 'EFI1' `
            -LogicalSectorSize 4096
        { Assert-OSDFirmwareDiskGeometry -Disk $Disk -FirmwareMode UEFI `
            -EfiMiB 299 } | Should -Throw
        { Assert-OSDFirmwareDiskGeometry -Disk $Disk -FirmwareMode UEFI `
            -EfiMiB 300 } | Should -Not -Throw
        $Disk.LogicalSectorSize = 512
        { Assert-OSDFirmwareDiskGeometry -Disk $Disk -FirmwareMode UEFI `
            -EfiMiB 200 } | Should -Not -Throw
    }

    It 'rejects BIOS disks above 2 TB before handing them to the planner' {
        $Disk = New-FixtureDisk -Number 3 -Serial 'LARGE' `
            -SizeBytes ([uint64]2000000000001)
        { Assert-OSDFirmwareDiskGeometry -Disk $Disk -FirmwareMode BIOS } |
            Should -Throw
    }
}

Describe 'Partition postconditions (synthetic, no hardware writes)' {
    BeforeAll {
        $RecoveryGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
    }

    It 'verifies GPT partition types, sizes, adjacency and attributes' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 128GB
        $Parts = @(New-FixturePartitionLayout -Plan $Plan)
        $Layout = Assert-OSDPartitionStructure -Parts $Parts `
            -Plan $Plan -RecoveryGuid $RecoveryGuid
        $Layout.WindowsIndex | Should -Be 2
        $Layout.RecoveryIndex | Should -Be 3
        $Parts[3].GptType = 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
        { Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw
        $Parts[3].GptType = $RecoveryGuid
        $Parts[3].NoDefaultDriveLetter = $false
        { Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw
    }

    It 'verifies BIOS System active and Recovery type 0x27' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 128GB -FirmwareMode BIOS
        $Parts = @(New-FixturePartitionLayout -Plan $Plan)
        (Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid).WindowsIndex | Should -Be 1
        $Parts[0].IsActive = $false
        { Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw
        $Parts[0].IsActive = $true
        $Parts[2].MbrType = 7
        { Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw
    }

    It 'rejects a gap larger than alignment between Windows and Recovery' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 128GB -FirmwareMode BIOS
        $Parts = @(New-FixturePartitionLayout -Plan $Plan)
        $Parts[2].Offset += 2MB
        { Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw
    }

    It 'verifies the optional MBR fourth Data partition and GPT Data GUID' {
        $Plan = New-OSDPartitionPlan -DiskSizeBytes 256GB -FirmwareMode BIOS `
            -WindowsSizeGiB 120 -CreateDataPartition $true
        $Parts = @(New-FixturePartitionLayout -Plan $Plan)
        (Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid).DataIndex | Should -Be 3
        $Parts[3].MbrType = 39
        { Assert-OSDPartitionStructure -Parts $Parts -Plan $Plan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw

        $GptPlan = New-OSDPartitionPlan -DiskSizeBytes 256GB `
            -WindowsSizeGiB 120 -CreateDataPartition $true
        $GptParts = @(New-FixturePartitionLayout -Plan $GptPlan)
        $GptParts[4].Guid = ''
        { Assert-OSDPartitionStructure -Parts $GptParts -Plan $GptPlan `
            -RecoveryGuid $RecoveryGuid } | Should -Throw
    }
}

Describe 'Task-sequence source protection (no disk writes)' {
    BeforeAll {
        Mock Get-Partition {
            if ($DriveLetter -eq 'C') {
                return [pscustomobject]@{ DiskNumber = 2 }
            }
            if ($DriveLetter -eq 'D') {
                return [pscustomobject]@{ DiskNumber = 9 }
            }
        }
        Mock Get-PSDrive {
            if ($Name -eq 'Z') {
                return [pscustomobject]@{
                    DisplayRoot = '\\server\share'
                    Root = 'Z:\'
                }
            }
        }
    }

    It 'rejects task-sequence files or a script cached on the selected disk' {
        { Assert-OSDPathOffTargetDisk -Path 'C:\_SMSTaskSequence' `
            -TargetDiskNumber 2 -Description 'Task-sequence data' } |
            Should -Throw
    }

    It 'allows a different disk, RAM drive or network share' {
        { Assert-OSDPathOffTargetDisk -Path 'D:\Packages\script.ps1' `
            -TargetDiskNumber 2 -Description 'Running script' } |
            Should -Not -Throw
        { Assert-OSDPathOffTargetDisk -Path 'X:\Windows\Temp' `
            -TargetDiskNumber 2 -Description 'Task-sequence logs' } |
            Should -Not -Throw
        { Assert-OSDPathOffTargetDisk -Path '\\server\share\script.ps1' `
            -TargetDiskNumber 2 -Description 'Running script' } |
            Should -Not -Throw
        { Assert-OSDPathOffTargetDisk -Path 'Z:\package' `
            -TargetDiskNumber 2 -Description 'Running script' } |
            Should -Not -Throw
    }

    It 'refuses unknown or relative local content paths' {
        { Assert-OSDPathOffTargetDisk -Path 'C:relative' `
            -TargetDiskNumber 2 -Description 'Running script' } |
            Should -Throw
        { Assert-OSDPathOffTargetDisk -Path 'Y:\unknown' `
            -TargetDiskNumber 2 -Description 'Task-sequence data' } |
            Should -Throw
    }

    It 'does not mistake device paths or local shares for remote package storage' {
        { Assert-OSDPathOffTargetDisk `
            -Path '\\?\Volume{11111111-1111-1111-1111-111111111111}\script.ps1' `
            -TargetDiskNumber 2 -Description 'Running script' } |
            Should -Throw
        { Assert-OSDPathOffTargetDisk -Path '\\localhost\C$\script.ps1' `
            -TargetDiskNumber 2 -Description 'Running script' } |
            Should -Throw
    }
}

Describe 'WinPE boot source and temporary drive letters (no disk writes)' {
    BeforeEach {
        Mock Get-Partition { }
        Mock Get-PSDrive { }
    }

    It 'accepts unused W and S when WinPE is on X' {
        { Assert-OSDWinPEDriveSafety -TargetDiskNumber 2 `
            -FirmwareMode BIOS -SystemRootPath 'X:\Windows' } |
            Should -Not -Throw
    }

    It 'rejects a Windows letter owned by a different disk' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 9 } } `
            -ParameterFilter { $DriveLetter -eq 'W' }
        { Assert-OSDWinPEDriveSafety -TargetDiskNumber 2 `
            -FirmwareMode UEFI -SystemRootPath 'X:\Windows' } |
            Should -Throw
    }

    It 'rejects an occupied BIOS System letter or a WinPE root on the target' {
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 9 } } `
            -ParameterFilter { $DriveLetter -eq 'S' }
        { Assert-OSDWinPEDriveSafety -TargetDiskNumber 2 `
            -FirmwareMode BIOS -SystemRootPath 'X:\Windows' } |
            Should -Throw
        Mock Get-Partition { [pscustomobject]@{ DiskNumber = 2 } } `
            -ParameterFilter { $DriveLetter -eq 'X' }
        { Assert-OSDWinPEDriveSafety -TargetDiskNumber 2 `
            -FirmwareMode UEFI -SystemRootPath 'X:\Windows' } |
            Should -Throw
    }
}

Describe 'Entry-point safety contract (static checks only)' {
    It 'offers Preview but no longer requires or accepts Apply' {
        $Names = @($Ast.ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath })
        $Names | Should -Contain 'Preview'
        $Names | Should -Contain 'PreviewFirmware'
        $Names | Should -Contain 'RequireUEFI'
        $Names | Should -Contain 'RequireBIOS'
        $Names | Should -Contain 'BiosSystemSizeMiB'
        $Names | Should -Contain 'MinimumWindowsSizeGiB'
        $Names | Should -Not -Contain 'Apply'
    }

    It 'places task-sequence and preview guards before DiskPart execution' {
        $Source = Get-Content -LiteralPath $ScriptPath -Raw
        $TaskSequenceGuard = $Source.IndexOf("if (-not `$Preview) {")
        $PreviewGuard = $Source.IndexOf("if (`$Preview) {", $Source.IndexOf('$Selected = Select-OSDTargetDisk'))
        $DiskPartCall = $Source.IndexOf('& $DiskPartPath /s $PlanPath')
        $TaskSequenceGuard | Should -BeGreaterThan 0
        $PreviewGuard | Should -BeGreaterThan $TaskSequenceGuard
        $DiskPartCall | Should -BeGreaterThan $PreviewGuard
    }

    It 'shows inventory and proposed commands before a preview can stop' {
        $Source = Get-Content -LiteralPath $ScriptPath -Raw
        $InventoryLog = $Source.IndexOf('foreach ($Item in $Inventory)')
        $SurfaceBlock = $Source.IndexOf('if ($SpacesDisks.Count -gt 0')
        $PreviewBlock = $Source.IndexOf('if ($Preview) {',
            $Source.IndexOf('$Selected = Select-OSDTargetDisk'))
        $Proposal = $Source.IndexOf('PREVIEW ONLY: the following commands')
        $CommandFileWrite = $Source.IndexOf('[System.IO.File]::WriteAllLines')
        $InventoryLog | Should -BeLessThan $SurfaceBlock
        $PreviewBlock | Should -BeLessThan $Proposal
        $Proposal | Should -BeLessThan $CommandFileWrite
    }

    It 'checks BIOS sector size and rejects a Windows 11 UEFI requirement before clean' {
        $Source = Get-Content -LiteralPath $ScriptPath -Raw
        $Firmware = $Source.IndexOf('$FirmwareMode = Get-OSDFirmwareMode')
        $UEFIGuard = $Source.IndexOf(
            'Assert-OSDFirmwarePolicy -FirmwareMode $FirmwareMode',
            $Firmware)
        $SectorGuard = $Source.IndexOf(
            'Assert-OSDFirmwareDiskGeometry -Disk $Selected')
        $CommandFileWrite = $Source.IndexOf('[System.IO.File]::WriteAllLines')
        $Firmware | Should -BeGreaterThan 0
        $UEFIGuard | Should -BeGreaterThan $Firmware
        $SectorGuard | Should -BeGreaterThan $UEFIGuard
        $CommandFileWrite | Should -BeGreaterThan $SectorGuard
    }

    It 'checks task-sequence cache and script locations before DiskPart' {
        $Source = Get-Content -LiteralPath $ScriptPath -Raw
        $CacheCheck = $Source.IndexOf(
            "TaskSequenceEnvironment.Value('_SMSTSMDataPath')")
        $ScriptCheck = $Source.IndexOf('Assert-OSDPathOffTargetDisk -Path $RunningScriptPath')
        $CommandFileWrite = $Source.IndexOf('[System.IO.File]::WriteAllLines')
        $PreviewGuard = $Source.IndexOf(
            'Assert-OSDTaskSequenceSource -TaskSequenceEnvironment $script:TSEnv')
        $RunGuard = $Source.LastIndexOf(
            'Assert-OSDTaskSequenceSource -TaskSequenceEnvironment $script:TSEnv',
            $CommandFileWrite)
        $CacheCheck | Should -BeGreaterThan 0
        $ScriptCheck | Should -BeGreaterThan $CacheCheck
        $PreviewGuard | Should -BeGreaterThan $ScriptCheck
        $RunGuard | Should -BeGreaterThan $PreviewGuard
        $CommandFileWrite | Should -BeGreaterThan $RunGuard
    }
}
