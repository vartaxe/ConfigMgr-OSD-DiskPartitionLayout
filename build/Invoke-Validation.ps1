[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root 'Invoke-OSDDiskLayout.ps1'
$Package = Join-Path $Root 'Scripts\Invoke-OSDDiskLayout.ps1'
$Test = Join-Path $Root 'Tests\Invoke-OSDDiskLayout.Tests.ps1'
$AnalyzerSettings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'

Import-Module Pester -RequiredVersion '5.7.1' -ErrorAction Stop
Import-Module PSScriptAnalyzer -RequiredVersion '1.25.0' -ErrorAction Stop

foreach ($Path in @($Source, $Package, $Test)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required validation file is missing: $Path"
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

Invoke-Pester -Path $Test -Output Detailed
