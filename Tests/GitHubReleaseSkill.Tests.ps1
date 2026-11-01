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
    It 'checks the exact fully qualified remote tag ref' {
        $script:SkillContent | Should -Match 'git ls-remote --exit-code --refs origin "refs/tags/\$PREV_TAG"'
        $script:SkillContent | Should -Not -Match 'git ls-remote --tags origin \| grep "refs/tags/\$PREV_TAG\$"'
    }

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
        $noTagSection | Should -Match 'empty Git tree'
        $noTagSection | Should -Not -Match 'go straight to Step 5'
        $script:SkillContent | Should -Match 'git hash-object -t tree --stdin'
        $script:SkillContent | Should -Match 'git log HEAD --oneline --no-merges'

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

        $stepSix = [regex]::Match(
            $script:SkillContent,
            '(?s)### Step 6 - Update release metadata and CHANGELOG\.md.*?(?=\r?\n---)'
        ).Value
        $stepSix | Should -Match 'Defer checksum regeneration and checksum validation'
        $stepSix | Should -Match 'all other maintained files have their final contents'

        $stepSeven = [regex]::Match(
            $script:SkillContent,
            '(?s)### Step 7 - Validate, commit and push.*?(?=\r?\n```bash)'
        ).Value
        $stepSeven | Should -Match 'regenerate checksums last'
        $stepSeven | Should -Match 'before the changelog is written'

        $script:SkillContent | Should -Not -Match 'Steps 1 - 4 are \*\*read-only reconnaissance\*\*'
        $script:SkillContent | Should -Match 'can change the\s+working tree and local refs'
    }
}
