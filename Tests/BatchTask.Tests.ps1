BeforeAll {
    $script:TaskTemplatePath = Join-Path $PSScriptRoot '..\.github\skills\batch-files\assets\task.txt'

    function Invoke-TaskWithCleanupFailure {
        param(
            [Parameter(Mandatory)]
            [int]$TaskExitCode
        )

        $taskPath = Join-Path $TestDrive ("task-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $runnerPath = Join-Path $TestDrive ("runner-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $logPath = Join-Path $TestDrive ("task-{0}.log" -f [guid]::NewGuid().ToString('N'))
        $tempPath = Join-Path $TestDrive ("locked-temp-{0}" -f [guid]::NewGuid().ToString('N'))
        $lockPath = Join-Path $tempPath 'locked.txt'
        $null = New-Item -ItemType Directory -Path $tempPath
        [IO.File]::WriteAllText($lockPath, 'locked')
        $lock = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read
        )
        $task = [IO.File]::ReadAllText($script:TaskTemplatePath, [Text.Encoding]::UTF8)
        $task = [regex]::Replace($task, "`r`n|`r|`n", "`r`n")
        $task = $task.Replace(
            'set "_logFileMyTask=%TEMP%\%~n0.log"',
            ('set "_logFileMyTask={0}"' -f $logPath)
        )
        $task = $task.Replace(
            'call :_makeTempDirMyTask',
            ('set "_tmpDirMyTask={0}"' -f $tempPath) + "`r`n" +
            'set "_tmpDirCreatedMyTask=1'
        )
        $task = $task.Replace(
            '    call :_logMyTask "Task operations complete."',
            ('    exit /b {0}' -f $TaskExitCode)
        )
        [IO.File]::WriteAllText($taskPath, $task, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllLines(
            $runnerPath,
            @('@echo off', ('call "{0}"' -f $taskPath), 'exit /b %ERRORLEVEL%'),
            [Text.Encoding]::ASCII
        )

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $env:ComSpec /d /c $runnerPath 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
            $lock.Dispose()
        }
        $directoryMatch = [regex]::Match(
            ($output -join "`n"),
            'Could not remove temporary directory "([^"]+)"'
        )
        [pscustomobject]@{
            Output = $output -join "`n"
            ExitCode = $exitCode
            LeftoverDirectory = $directoryMatch.Groups[1].Value
            LogPath = $logPath
            TempPath = $tempPath
        }
    }

    function Invoke-TaskWithBangLogPath {
        $taskPath = Join-Path $TestDrive ("task-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $runnerPath = Join-Path $TestDrive ("runner-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $logPath = Join-Path $TestDrive 'build!cache.log'
        $task = [IO.File]::ReadAllText($script:TaskTemplatePath, [Text.Encoding]::UTF8)
        $task = [regex]::Replace($task, "`r`n|`r|`n", "`r`n")
        $task = $task.Replace(
            'set "_logFileMyTask=%TEMP%\%~n0.log"',
            ('set "_logFileMyTask={0}"' -f $logPath)
        )
        [IO.File]::WriteAllText($taskPath, $task, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllLines(
            $runnerPath,
            @('@echo off', ('call "{0}"' -f $taskPath), 'exit /b %ERRORLEVEL%'),
            [Text.Encoding]::ASCII
        )
        $output = @(& $env:ComSpec /d /c $runnerPath 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{
            Output = $output -join "`n"
            ExitCode = $LASTEXITCODE
            LogPath = $logPath
        }
    }

    function Invoke-TaskHelpWithInheritedTempOwnership {
        $taskPath = Join-Path $TestDrive ("task-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $runnerPath = Join-Path $TestDrive ("runner-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
        $parentTempPath = Join-Path $TestDrive ("parent-temp-{0}" -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $parentTempPath
        $task = [IO.File]::ReadAllText($script:TaskTemplatePath, [Text.Encoding]::UTF8)
        $task = [regex]::Replace($task, "`r`n|`r|`n", "`r`n")
        $task = $task.Replace('call :_showHelpMyTask', 'goto _removeBatchVariablesMyTask')
        [IO.File]::WriteAllText($taskPath, $task, [Text.Encoding]::ASCII)
        $lines = @(
            '@echo off'
            'setlocal DisableDelayedExpansion'
            'set "_tmpDirCreatedMyTask=1"'
            ('set "_tmpDirMyTask={0}"' -f $parentTempPath)
            ('call "{0}" --help >nul' -f $taskPath)
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

Describe 'Batch task temporary-directory cleanup' {
    It 'reports cleanup failure and returns nonzero only when the task succeeded' -ForEach @(
        @{ TaskExitCode = 0; ExpectedExitCode = 1 }
        @{ TaskExitCode = 7; ExpectedExitCode = 7 }
    ) {
        $result = Invoke-TaskWithCleanupFailure -TaskExitCode $TaskExitCode
        try {
            $result.Output | Should -Match 'ERROR: Could not remove temporary directory'
            $result.LeftoverDirectory | Should -Not -BeNullOrEmpty
            $result.ExitCode | Should -Be $ExpectedExitCode
        } finally {
            if ($result.LeftoverDirectory -and (Test-Path -LiteralPath $result.LeftoverDirectory)) {
                Remove-Item -LiteralPath $result.LeftoverDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $result.LogPath) {
                Remove-Item -LiteralPath $result.LogPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'writes logs when the configured log path contains an exclamation mark' {
        $result = Invoke-TaskWithBangLogPath
        try {
            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $result.LogPath | Should -BeTrue
            Get-Content -LiteralPath $result.LogPath -Raw | Should -Match 'Task started:'
        } finally {
            if (Test-Path -LiteralPath $result.LogPath) {
                Remove-Item -LiteralPath $result.LogPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'does not delete inherited temporary state on an early help exit' {
        $result = Invoke-TaskHelpWithInheritedTempOwnership
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
