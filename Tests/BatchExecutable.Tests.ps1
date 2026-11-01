BeforeAll {
    $script:ExecutableTemplatePath = Join-Path $PSScriptRoot '..\.github\skills\batch-files\assets\executable.txt'

    function Invoke-ExecutableOptionWithInheritedTempOwnership {
        param(
            [Parameter(Mandatory)]
            [string]$Option
        )

        $toolPath = Join-Path $TestDrive ("tool-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $runnerPath = Join-Path $TestDrive ("runner-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $parentTempPath = Join-Path $TestDrive ("parent-temp-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $parentTempPath

        $tool = [IO.File]::ReadAllText($script:ExecutableTemplatePath, [Text.Encoding]::UTF8)
        $tool = [regex]::Replace($tool, "`r`n|`r|`n", "`r`n")
        [IO.File]::WriteAllText($toolPath, $tool, [Text.Encoding]::ASCII)
        $lines = @(
            '@echo off'
            'setlocal DisableDelayedExpansion'
            'set "_tmpDirCreatedMyTool=1"'
            ('set "_tmpDirMyTool={0}"' -f $parentTempPath)
            ('call "{0}" {1} >nul' -f $toolPath, $Option)
            ('if exist "{0}" echo PARENT_TEMP_PRESERVED' -f $parentTempPath)
            'endlocal & exit /b %ERRORLEVEL%'
        )
        [IO.File]::WriteAllLines($runnerPath, $lines, [Text.Encoding]::ASCII)
        $output = @(& $env:ComSpec /d /c $runnerPath 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{
            Output = $output -join "`n"
            ExitCode = $LASTEXITCODE
            ParentTempPath = $parentTempPath
        }
    }
}

Describe 'Batch executable temporary-directory ownership' {
    It 'does not delete inherited temporary state on an early <Option> exit' -ForEach @(
        @{ Option = '/?' }
        @{ Option = '--help' }
        @{ Option = '-v' }
    ) {
        $result = Invoke-ExecutableOptionWithInheritedTempOwnership -Option $Option
        try {
            $result.Output | Should -Match 'PARENT_TEMP_PRESERVED'
            Test-Path -LiteralPath $result.ParentTempPath | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $result.ParentTempPath) {
                Remove-Item -LiteralPath $result.ParentTempPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
