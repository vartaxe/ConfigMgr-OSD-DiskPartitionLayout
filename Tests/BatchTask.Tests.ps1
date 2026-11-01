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
        $task = [IO.File]::ReadAllText($script:TaskTemplatePath, [Text.Encoding]::UTF8)
        $task = [regex]::Replace($task, "`r`n|`r|`n", "`r`n")
        $task = $task.Replace(
            'set "_logFileMyTask=%TEMP%\%~n0.log"',
            ('set "_logFileMyTask={0}"' -f $logPath)
        )
        $task = $task.Replace(
            '    call :_logMyTask "Task operations complete."',
            ('    cd /D "%_tmpDirMyTask%"' + "`r`n" + ('    exit /b {0}' -f $TaskExitCode))
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
}
