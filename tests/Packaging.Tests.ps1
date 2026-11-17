#Requires -Version 7.0
<#
.SYNOPSIS
    Packaging tests for M7 (plan Task 18 Step 1): the boot.wim degrade
    decision. Pure function tests; the build wires Invoke-Degrade in
    before the iso step and fails with the "please turn off -Office/-Chrome"
    guidance when the image is over the 3 GB cap.
#>

BeforeAll { . "$PSScriptRoot/../src/build/lib/Stages.ps1" }

Describe 'Invoke-Degrade' {
    It 'drops office first when over the cap' {
        $r = Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @('office', 'chrome')
        $r.TooBig | Should -BeTrue
        $r.NextToDrop | Should -Be 'office'
    }

    It 'drops chrome next when office is already off' {
        $r = Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @('chrome', 'photos')
        $r.TooBig | Should -BeTrue
        $r.NextToDrop | Should -Be 'chrome'
    }

    It 'is fine under the cap' {
        (Invoke-Degrade -CurrentWimBytes (2.5GB) -Enabled @('office', 'chrome')).TooBig | Should -BeFalse
    }

    It 'exhausts the order without repeating' {
        (Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @()).NextToDrop | Should -BeNullOrEmpty
    }

    It 'returns the approved degrade order office, chrome, photos, mediaplayer' {
        Get-DegradeOrder | Should -Be @('office', 'chrome', 'photos', 'mediaplayer')
    }
}
