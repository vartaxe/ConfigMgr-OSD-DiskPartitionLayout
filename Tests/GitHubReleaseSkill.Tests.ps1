BeforeAll {
    $script:SkillPath = Join-Path $PSScriptRoot '..\.github\skills\github-release\SKILL.md'
    $script:SkillContent = Get-Content -LiteralPath $script:SkillPath -Raw
    $script:BashPattern = [regex]::Match($script:SkillContent, "grep -E '([^']+)'").Groups[1].Value
    $script:PowerShellPattern = [regex]::Match(
        $script:SkillContent,
        "Where-Object \{ \`$_ -match '([^']+)' \}"
    ).Groups[1].Value
}

Describe 'GitHub release tag selection' {
    It 'compares stable numeric versions and retains original tags in both shell examples' {
        $script:BashPattern | Should -Not -BeNullOrEmpty
        $script:PowerShellPattern | Should -Not -BeNullOrEmpty

        $script:SkillContent | Should -Match '(?s)sort -t .*?-k1,1Vr'
        $script:SkillContent | Should -Match '\[version\]\(\$_ -replace'
        $script:SkillContent | Should -Match 'among `v1\.9\.0` and `2\.0\.0`, select `2\.0\.0`'

        foreach ($Pattern in $script:BashPattern, $script:PowerShellPattern) {
            foreach ($Tag in '1.2.3', 'v1.2.3', 'V1.2.3') {
                [regex]::IsMatch($Tag, $Pattern) | Should -BeTrue -Because "$Tag is a stable three-component version"
            }
            foreach ($Tag in '1.2.3-rc.1', 'v1.2.3-beta', '1.2.3+build.7', 'v1.2.3-extra') {
                [regex]::IsMatch($Tag, $Pattern) | Should -BeFalse -Because "$Tag has a suffix and is not an exact stable version tag"
            }
        }
    }

    It 'keeps release-metadata discovery and version confirmation on the no-tag path' {
        $noTagSection = [regex]::Match(
            $script:SkillContent,
            '(?s)- If \*\*no tags exist at all\*\*.*?(?=\r?\n- If the tag does not point)'
        ).Value
        $noTagSection | Should -Match 'propose `1\.0\.0`'
        $noTagSection | Should -Match 'release-metadata and automation discovery in Step 3d'
        $noTagSection | Should -Match 'wait for the owner''s\s+confirmation'
        $noTagSection | Should -Not -Match 'go straight to Step 5'

        $stepFour = [regex]::Match(
            $script:SkillContent,
            '(?s)### Step 4 - Determine the next SemVer version.*?(?=\r?\n---)'
        ).Value
        $stepFour | Should -Match 'When `PREV_TAG` is `\(none\)`'
        $stepFour | Should -Match 'Wait for confirmation before proceeding'
        $stepFive = [regex]::Match(
            $script:SkillContent,
            '(?s)### Step 5 - Create the release branch.*?(?=\r?\n```bash)'
        ).Value
        $stepFive | Should -Match 'Only after the owner has explicitly confirmed'
    }
}
