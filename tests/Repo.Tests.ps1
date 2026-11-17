BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'repository skeleton' {
    It 'has GPL-3.0 license text' {
        $license = Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE') -Raw
        $license | Should -Match 'GNU GENERAL PUBLIC LICENSE'
        $license | Should -Match 'Version 3, 29 June 2007'
    }

    It 'README states the MICPE memory requirement' {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $readme | Should -Match '4 GB'
    }

    It 'README documents the install.mic protocol' {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $readme | Should -Match 'install\.mic'
        $readme | Should -Match 'sources\\install\.wim'
    }

    It 'design doc is present' {
        Test-Path -LiteralPath (Join-Path $repoRoot 'docs/design.md') | Should -BeTrue
    }

    It 'plan doc is present' {
        Test-Path -LiteralPath (Join-Path $repoRoot 'docs/plan.md') | Should -BeTrue
    }
}

Describe 'app/ component layout' {
    BeforeAll {
        $script:appReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'app/README.md') -Raw
        $script:templateBat = Get-Content -LiteralPath (Join-Path $repoRoot 'app/_template/install.bat') -Raw
    }

    It 'install.bat runs in CI against a mounted boot.wim, never inside the PE' {
        # User decision 2026-11-17: install.bat integrates the component
        # during the build (copy files, write registry); installing
        # software from inside the PE wastes performance. Pin the wording
        # so the semantics cannot silently drift back.
        $script:appReadme | Should -Match 'CI 里'
        $script:appReadme | Should -Match '绝不在 PE 启动后运行'
        $script:templateBat | Should -Match 'NEVER runs inside the PE'
    }

    It 'marks chrome and office as pending until M5' {
        $script:appReadme | Should -Match 'Chrome.*待补（M5）'
        $script:appReadme | Should -Match 'Office 2016.*待补（M5）'
    }
}
