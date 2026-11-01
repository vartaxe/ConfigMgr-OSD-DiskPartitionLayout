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
}
