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
