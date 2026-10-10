[CmdletBinding()]
param(
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root 'Invoke-OSDDiskLayout.ps1'
$Package = Join-Path $Root 'Scripts\Invoke-OSDDiskLayout.ps1'
$Test = Join-Path $Root 'Tests\Invoke-OSDDiskLayout.Tests.ps1'
$AnalyzerSettings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'

Import-Module Pester -RequiredVersion '6.2.0' -ErrorAction Stop
Import-Module PSScriptAnalyzer -RequiredVersion '1.25.0' -ErrorAction Stop

foreach ($Path in @($Source, $Package, $Test)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required validation file is missing: $Path"
    }
}

if ($PSBoundParameters.ContainsKey('Tag')) {
    $VersionMatch = [regex]::Match(
        (Get-Content -LiteralPath $Source -Raw),
        '(?m)^\s*Version:\s*(\d+\.\d+\.\d+)\.')
    if (-not $VersionMatch.Success -or
        $Tag -cnotmatch '^v\d+\.\d+\.\d+$' -or
        $Tag.Substring(1) -cne $VersionMatch.Groups[1].Value) {
        throw 'Tag does not match the documented script version.'
    }
}

$Findings = @(
    Invoke-ScriptAnalyzer -Path (Join-Path $Root 'Scripts') -Recurse -Settings $AnalyzerSettings -Severity Error, Warning
    Invoke-ScriptAnalyzer -Path (Join-Path $Root 'Tests') -Recurse -Settings $AnalyzerSettings -Severity Error, Warning
    Invoke-ScriptAnalyzer -Path (Join-Path $Root 'build') -Recurse -Settings $AnalyzerSettings -Severity Error, Warning
)
if ($Findings.Count -gt 0) {
    $Findings | Format-Table
    throw 'PSScriptAnalyzer findings require review.'
}

$SourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$PackageHash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash
if ($SourceHash -ne $PackageHash) {
    throw 'Root and package script copies differ.'
}

foreach ($Path in @($Source, $Package, $Test)) {
    $Tokens = $null
    $Errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$Tokens, [ref]$Errors) | Out-Null
    if ($Errors.Count -gt 0) {
        throw "PowerShell parse failed: $Path`n$($Errors | ForEach-Object Message | Out-String)"
    }
}

$Result = Invoke-Pester -Path (Join-Path $Root 'Tests') -Output Detailed -PassThru
if ($null -eq $Result -or $Result.Result -ne 'Passed' -or $Result.TotalCount -eq 0 -or
    $Result.FailedCount -gt 0 -or $Result.FailedContainersCount -gt 0 -or
    $Result.FailedBlocksCount -gt 0 -or $Result.SkippedCount -gt 0 -or
    $Result.NotRunCount -gt 0) {
    throw 'Pester did not complete with a fully passing, nonempty test suite.'
}

$Expected = @{}
Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
    Where-Object {
        $_.FullName -notlike "$Root\.git\*" -and
        $_.Name -ne 'CHECKSUMS.txt'
    } |
    ForEach-Object {
        $RelativePath = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $Expected[$RelativePath] = $_.FullName
    }

$Manifest = @{}
foreach ($Line in Get-Content -LiteralPath (Join-Path $Root 'CHECKSUMS.txt')) {
    if ($Line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') {
        throw "Malformed checksum entry: $Line"
    }
    $Hash = $Matches[1]
    $RelativePath = $Matches[2]
    if ($Manifest.ContainsKey($RelativePath)) {
        throw "Duplicate checksum entry: $RelativePath"
    }
    $Manifest[$RelativePath] = $Hash
}

foreach ($RelativePath in $Expected.Keys) {
    if (-not $Manifest.ContainsKey($RelativePath)) {
        throw "Missing checksum entry: $RelativePath"
    }
    $ActualHash = (Get-FileHash -LiteralPath $Expected[$RelativePath] `
        -Algorithm SHA256).Hash
    if ($ActualHash -ine $Manifest[$RelativePath]) {
        throw "Checksum mismatch: $RelativePath"
    }
}
foreach ($RelativePath in $Manifest.Keys) {
    if (-not $Expected.ContainsKey($RelativePath)) {
        throw "Unexpected checksum entry: $RelativePath"
    }
}
