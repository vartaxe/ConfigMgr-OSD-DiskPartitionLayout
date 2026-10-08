Describe 'Project branding and Pages shell' {
    BeforeAll {
        $Root = Split-Path -Parent $PSScriptRoot
        $Readme = Get-Content -LiteralPath (Join-Path $Root 'README.md') -Raw
        $Index = Get-Content -LiteralPath (Join-Path $Root 'index.md') -Raw
        $TaskSequence = Get-Content -LiteralPath (Join-Path $Root 'TASK-SEQUENCE.md') -Raw
        $Script = Get-Content -LiteralPath (Join-Path $Root 'Invoke-OSDDiskLayout.ps1') -Raw
        $ExpectedVersion = '1.0.2'
    }

    It 'provides accessible desktop and compact banner artwork' {
        foreach ($Name in 'banner.svg', 'banner-compact.svg', 'favicon.svg') {
            $Path = Join-Path $Root "assets\$Name"
            [xml]$Svg = Get-Content -LiteralPath $Path -Raw
            $Svg.DocumentElement.GetAttribute('role') | Should -Be 'img'

            $Labels = $Svg.DocumentElement.GetAttribute('aria-labelledby').Split(' ')
            $Labels.Count | Should -Be 2
            foreach ($Label in $Labels) {
                $Svg.SelectSingleNode("//*[@id='$Label']") | Should -Not -BeNullOrEmpty
            }
            $Svg.SelectSingleNode("//*[local-name()='title']") | Should -Not -BeNullOrEmpty
            $Svg.SelectSingleNode("//*[local-name()='desc']") | Should -Not -BeNullOrEmpty
        }
    }

    It 'uses responsive banners with descriptive alternative text on both landing pages' {
        $Readme | Should -Match '<source[^>]+banner-compact\.svg'
        $Readme | Should -Match '<img[^>]+banner\.svg[^>]+alt="[^"]+"[^>]+width="1280"[^>]+height="320"'
        $Index | Should -Match '<source[^>]+banner-compact\.svg'
        $Index | Should -Match '<img[^>]+banner\.svg[^>]+alt="[^"]+"[^>]+width="1280"[^>]+height="320"'
    }

    It 'keeps the destructive warning and unvalidated deployment boundary visible' {
        $Readme | Should -Match '(?i)irreversibly cleans and repartitions'
        $Readme | Should -Match '(?i)not field-certified'
        $Index | Should -Match '(?i)cleans and repartitions the selected disk'
        $Index | Should -Match '(?i)not field-certified'
    }

    It 'keeps current release metadata aligned across published surfaces' {
        $EscapedVersion = [regex]::Escape($ExpectedVersion)
        $Readme | Should -Match "Current version: $EscapedVersion"
        $Readme | Should -Match "releases/tag/v$EscapedVersion"
        $Index | Should -Match "Current version: $EscapedVersion"
        $Index | Should -Match "releases/tag/v$EscapedVersion"
        $TaskSequence | Should -Match "Invoke-OSDDiskLayout\.ps1.*\($EscapedVersion\)"
        $Script | Should -Match "Version: $EscapedVersion\."
    }

    It 'uses the shared Cayman site configuration and safe navigation paths' {
        $Config = Get-Content -LiteralPath (Join-Path $Root '_config.yml') -Raw
        $Layout = Get-Content -LiteralPath (Join-Path $Root '_layouts\default.html') -Raw
        $Config | Should -Match 'theme: jekyll-theme-cayman'
        $Config | Should -Match 'baseurl: /ConfigMgr-OSD-DiskPartitionLayout'
        $Config | Should -Match 'url: /TASK-SEQUENCE\.html'
        $Index | Should -Match ([regex]::Escape(
            '[Source README](https://github.com/vartaxe/ConfigMgr-OSD-DiskPartitionLayout#readme)'))
        $Layout | Should -Match 'Skip to content'
        $Layout | Should -Match 'aria-label="Project navigation"'
    }

    It 'restores PSGallery before installing validation modules' {
        $Workflow = Get-Content -LiteralPath (Join-Path $Root '.github\workflows\ci.yml') -Raw
        $Workflow | Should -Match 'Get-PSRepository -Name PSGallery'
        $Workflow | Should -Match 'Register-PSRepository -Default'
    }

    It 'fails validation for incomplete or nonpassing test runs' {
        $Validation = Get-Content -LiteralPath (Join-Path $Root 'build\Invoke-Validation.ps1') -Raw
        foreach ($Gate in 'Result', 'TotalCount', 'FailedCount', 'FailedContainersCount',
            'FailedBlocksCount', 'SkippedCount', 'NotRunCount') {
            $Validation | Should -Match ([regex]::Escape("Result.$Gate"))
        }
    }
}
