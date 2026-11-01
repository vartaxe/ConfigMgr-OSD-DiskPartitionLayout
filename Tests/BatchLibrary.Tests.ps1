BeforeAll {
    $script:LibraryPath = Join-Path $PSScriptRoot '..\.github\skills\batch-files\assets\library.txt'
    $script:ExecutablePath = Join-Path $PSScriptRoot ("PadRight-library-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
    $script:RunnerPath = Join-Path $PSScriptRoot ("PadRight-runner-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
    $library = [IO.File]::ReadAllText($script:LibraryPath, [Text.Encoding]::UTF8)
    $library = [regex]::Replace($library, "`r`n|`r|`n", "`r`n")
    [IO.File]::WriteAllText($script:ExecutablePath, $library, [Text.Encoding]::ASCII)

    function Invoke-BatchLibrary {
        param(
            [Parameter(Mandatory)]
            [string]$Function,
            [string[]]$Arguments = @()
        )

        $quotedArguments = @($Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
        $call = 'call "{0}" {1} {2}' -f $script:ExecutablePath, $Function, $quotedArguments
        [System.IO.File]::WriteAllLines(
            $script:RunnerPath,
            @('@echo off', 'setlocal DisableDelayedExpansion', $call, 'endlocal & exit /b %ERRORLEVEL%'),
            [System.Text.Encoding]::ASCII
        )
        $output = @(& $env:ComSpec /d /c $script:RunnerPath 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{
            Output = $output -join "`n"
            ExitCode = $LASTEXITCODE
        }
    }

    function Invoke-PadRight {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Value,
            [Parameter(Mandatory)]
            [string]$Width
        )

        Invoke-BatchLibrary -Function 'padRight' -Arguments @($Value, $Width)
    }

    function Invoke-BatchLibraryWithDelayedExpansion {
        param(
            [Parameter(Mandatory)]
            [string]$Function,
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Value,
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$ExpectedValue,
            [string]$Width,
            [switch]$NamedVariable
        )

        $batchValue = $Value.Replace('^', '^^').Replace('!', '^!')
        $batchExpectedValue = $ExpectedValue.Replace('^', '^^').Replace('!', '^!')
        $batchWidth = if ($null -eq $Width) { '' } else { $Width.Replace('^', '^^').Replace('!', '^!') }
        $call = if ($NamedVariable) {
            'call "{0}" {1} testValue' -f $script:ExecutablePath, $Function
        } else {
            'call "{0}" {1} %%testValue%% %%testWidth%%' -f $script:ExecutablePath, $Function
        }
        $lines = @(
            '@echo off'
            'setlocal EnableDelayedExpansion'
            ('set "testValue={0}"' -f $batchValue)
            ('set "expectedValue={0}"' -f $batchExpectedValue)
            ('set "testWidth={0}"' -f $batchWidth)
            ('set "expectedWidth={0}"' -f $batchWidth)
            'set "probe=enabled"'
            $call
            'set "_callStatus=!ERRORLEVEL!"'
            'if "!testValue!"=="!expectedValue!" echo VALUE_PRESERVED'
            'echo VALUE=!testValue!'
            'if "!testWidth!"=="!expectedWidth!" echo WIDTH_PRESERVED'
            'if "!probe!"=="enabled" echo DELAYED_EXPANSION_RESTORED'
            'endlocal & exit /b %_callStatus%'
        )
        [System.IO.File]::WriteAllLines($script:RunnerPath, $lines, [System.Text.Encoding]::ASCII)
        $output = @(& $env:ComSpec /d /c $script:RunnerPath 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{
            Output = $output -join "`n"
            ExitCode = $LASTEXITCODE
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:RunnerPath, $script:ExecutablePath -Force -ErrorAction SilentlyContinue
}

Describe 'Batch library padRight' {
    It 'pads a value to the requested width' {
        $result = Invoke-PadRight -Value 'Hello' -Width '8'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeExactly 'Hello   '
    }

    It 'pads an explicitly empty value with spaces' {
        $result = Invoke-PadRight -Value '' -Width '4'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeExactly '    '
    }

    It 'accepts a width with leading zeroes' {
        $result = Invoke-PadRight -Value 'A' -Width '0004'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeExactly 'A   '
    }

    It 'preserves exclamation marks in the value' {
        $result = Invoke-PadRight -Value 'A!B!C' -Width '7'
        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeExactly 'A!B!C  '
    }

    It 'rejects a semicolon-prefixed nonnumeric width' {
        $result = Invoke-PadRight -Value 'A' -Width ';bad'
        $result.Output | Should -BeExactly 'ERROR: padRight width must be an integer from 0 to 8000.'
        $result.ExitCode | Should -Be 1
    }

    It 'rejects an exclamation-containing width without expanding it' {
        $result = Invoke-PadRight -Value 'A' -Width '1!MISSING!0'
        $result.Output | Should -BeExactly 'ERROR: padRight width must be an integer from 0 to 8000.'
        $result.ExitCode | Should -Be 1
    }

    It 'preserves exclamation marks and rejects invalid widths with caller delayed expansion enabled' {
        $result = Invoke-BatchLibraryWithDelayedExpansion -Function 'padRight' `
            -Value 'A!B' -ExpectedValue 'A!B' -Width '1!MISSING!0'
        $result.Output | Should -Match 'ERROR: padRight width must be an integer from 0 to 8000\.'
        $result.Output | Should -Match 'VALUE_PRESERVED'
        $result.Output | Should -Match 'WIDTH_PRESERVED'
        $result.Output | Should -Match 'DELAYED_EXPANSION_RESTORED'
        $result.ExitCode | Should -Be 1
    }

    It 'preserves named-variable outputs with caller delayed expansion enabled' {
        $result = Invoke-BatchLibraryWithDelayedExpansion -Function 'trimWhitespace' `
            -Value '  A!B  ' -ExpectedValue 'A!B' -NamedVariable
        $result.Output | Should -Match 'VALUE_PRESERVED'
        $result.Output | Should -Match 'DELAYED_EXPANSION_RESTORED'
        $result.ExitCode | Should -Be 0
    }

    It 'preserves converted named-variable outputs with caller delayed expansion enabled' {
        $result = Invoke-BatchLibraryWithDelayedExpansion -Function 'toLower' `
            -Value 'A!B' -ExpectedValue 'a!b' -NamedVariable
        $result.Output | Should -Match 'VALUE_PRESERVED'
        $result.Output | Should -Match 'DELAYED_EXPANSION_RESTORED'
        $result.ExitCode | Should -Be 0
    }

    It 'preserves mixed caret and exclamation marks in named-variable outputs' {
        $result = Invoke-BatchLibraryWithDelayedExpansion -Function 'trimWhitespace' `
            -Value '  A^!B  ' -ExpectedValue 'A^!B' -NamedVariable
        $result.Output | Should -Match 'VALUE=A\^!B'
        $result.Output | Should -Match 'VALUE_PRESERVED'
        $result.ExitCode | Should -Be 0
    }

    It 'preserves exclamation marks in log messages with caller delayed expansion enabled' {
        $result = Invoke-BatchLibraryWithDelayedExpansion -Function 'logMessage' `
            -Value 'INFO' -ExpectedValue 'INFO' -Width 'message!B'
        $result.Output | Should -Match '\[INFO\] message!B'
        $result.Output | Should -Match 'DELAYED_EXPANSION_RESTORED'
        $result.ExitCode | Should -Be 0
    }

    It 'returns a nonzero ERRORLEVEL for an unknown function' {
        $result = Invoke-BatchLibrary -Function 'notAFunction'
        $result.Output | Should -Match '^ERROR: Unknown function "notAFunction"\. Run ".+ /\?" for usage\.$'
        $result.ExitCode | Should -Be 1
    }
}
