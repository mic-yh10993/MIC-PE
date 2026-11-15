BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Stages.ps1"
}

Describe 'Get-StageSteps' {
    It 'm1 contains only base steps in order' {
        Get-StageSteps -Stage 'm1' | Should -Be @('base', 'reseed', 'iso')
    }

    It 'm4 adds shell, runtimes, components and uwp without duplicates' {
        $steps = Get-StageSteps -Stage 'm4'
        $steps | Should -Be @('base', 'reseed', 'explorer', 'runtimes', 'components', 'uwp', 'iso')
        ($steps | Select-Object -Unique).Count | Should -Be $steps.Count
    }

    It 'm6 adds payload, brand and installer' {
        Get-StageSteps -Stage 'm6' | Should -Be @(
            'base', 'reseed', 'explorer', 'runtimes', 'components', 'uwp',
            'payload', 'brand', 'installer', 'iso')
    }

    It 'all ends with iso and equals m7' {
        (Get-StageSteps -Stage 'all')[-1] | Should -Be 'iso'
        Get-StageSteps -Stage 'all' | Should -Be (Get-StageSteps -Stage 'm7')
    }

    It 'every stage ends with iso' {
        foreach ($stage in 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'all') {
            (Get-StageSteps -Stage $stage)[-1] | Should -Be 'iso'
        }
    }

    It 'stage steps are monotonically additive' {
        $order = 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7'
        for ($i = 1; $i -lt $order.Count; $i++) {
            $previous = Get-StageSteps -Stage $order[$i - 1]
            $current = Get-StageSteps -Stage $order[$i]
            foreach ($step in $previous) {
                $current | Should -Contain $step
            }
        }
    }

    It 'rejects an unknown stage' {
        { Get-StageSteps -Stage 'm99' } | Should -Throw
    }
}

Describe 'Invoke-Degrade' {
    It 'drops office first when over the cap' {
        $result = Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @('office', 'chrome')
        $result.TooBig | Should -BeTrue
        $result.NextToDrop | Should -Be 'office'
    }

    It 'skips items that are not enabled' {
        (Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @('chrome')).NextToDrop | Should -Be 'chrome'
    }

    It 'is fine under the cap' {
        (Invoke-Degrade -CurrentWimBytes (2.5GB) -Enabled @('office', 'chrome')).TooBig | Should -BeFalse
    }

    It 'reports too big with nothing left to drop' {
        $result = Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @()
        $result.TooBig | Should -BeTrue
        $result.NextToDrop | Should -BeNullOrEmpty
    }
}

Describe 'degrade order' {
    It 'is office, chrome, photos, mediaplayer' {
        Get-DegradeOrder | Should -Be @('office', 'chrome', 'photos', 'mediaplayer')
    }
}
