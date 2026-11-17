#Requires -Version 7.0
<#
.SYNOPSIS
    Explorer shell assembly: SOFTWARE hive swap, shell file extraction, checks.

.DESCRIPTION
    A stock WinPE has no shell. Making Explorer run needs three things that
    cannot be added by copying DLLs alone:

    1. The full SOFTWARE hive from install.wim. WinPE's own hive is pruned and
       lacks the AppX/AppModel/StateRepository/Windows.UI registration that both
       Explorer and UWP read at startup. Patching cannot add it back.
    2. ProgramData\Microsoft\Windows\AppRepository must exist as a directory,
       even empty; StateRepository refuses to initialise without it.
    3. Windows\SystemTemp must exist, or the photo stack reports every image as
       corrupted.
#>

function Install-ExplorerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $InstallWim,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [string] $WimlibPath = 'wimlib-imagex',

        [int] $InstallIndex = 1
    )

    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    Assert-PathExists -Path $InstallWim -Label 'install.wim'

    Write-Step 'swapping the SOFTWARE hive from install.wim'
    $targetConfig = Join-Path $MountDir 'Windows/System32/config'
    Assert-PathExists -Path $targetConfig -Label 'PE config directory'

    $staging = Join-Path $MountDir 'Windows/System32/config/.micpe-staging'
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # wimlib flattens PATH arguments into the destination by default; only
    # --preserve-dir-structure keeps the archive path, and the assertion
    # below looks for the hive at its nested path. Without the flag Build
    # run 44027407243 died here with "extracted SOFTWARE hive not found"
    # even though the extract itself reported 100% done.
    & $WimlibPath extract $InstallWim $InstallIndex 'Windows/System32/config/SOFTWARE' "--dest-dir=$staging" '--preserve-dir-structure' |
        Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "failed to extract SOFTWARE from $InstallWim"

    $extracted = Join-Path $staging 'Windows/System32/config/SOFTWARE'
    Assert-PathExists -Path $extracted -Label 'extracted SOFTWARE hive'

    Copy-Item -LiteralPath $extracted -Destination (Join-Path $targetConfig 'SOFTWARE') -Force
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    Write-Step 'creating the directories Explorer and UWP require'
    foreach ($relative in 'ProgramData/Microsoft/Windows/AppRepository', 'Windows/SystemTemp') {
        $path = Join-Path $MountDir $relative
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-SubStep "created $relative"
        }
    }

    Write-Step 'extracting the Explorer shell file set'
    $patterns = Read-Whitelist -Path (Join-Path $RepoRoot 'src/filelists/20-explorer.txt')
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $patterns -WimlibPath $WimlibPath

    Write-Step 'extracting the base CmdPE file set'
    $basePatterns = Read-Whitelist -Path (Join-Path $RepoRoot 'src/filelists/10-cmdpe.txt')
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $basePatterns -WimlibPath $WimlibPath
}

function Assert-ExplorerPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    $explorer = Join-Path $MountDir 'Windows/explorer.exe'
    if (-not (Test-Path -LiteralPath $explorer)) {
        $missing.Add("explorer.exe (expected $explorer)")
    }

    $system32 = Join-Path $MountDir 'Windows/System32'
    $stateRepo = @()
    if (Test-Path -LiteralPath $system32) {
        $stateRepo = @(Get-ChildItem -LiteralPath $system32 -Filter 'Windows.StateRepository*' -File -ErrorAction SilentlyContinue)
    }
    if ($stateRepo.Count -lt 4) {
        $missing.Add("Windows.StateRepository* family (found $($stateRepo.Count), need at least 4)")
    }

    foreach ($dir in 'ProgramData/Microsoft/Windows/AppRepository', 'Windows/SystemTemp') {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir $dir))) {
            $missing.Add("$dir directory")
        }
    }

    foreach ($dll in 'CoreMessaging.dll', 'twinapi.appcore.dll', 'twinui.pcshell.dll') {
        if (-not (Test-Path -LiteralPath (Join-Path $system32 $dll))) {
            $missing.Add("System32/$dll")
        }
    }

    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "Explorer shell is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'explorer shell artifacts verified'
}

function Set-BootShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    $shellSrc = Join-Path $RepoRoot 'src/shell'
    Assert-PathExists -Path $shellSrc -Label 'shell source directory'

    $startnet = Join-Path $MountDir 'Windows/System32/startnet.cmd'
    Copy-Item -LiteralPath (Join-Path $shellSrc 'startnet.cmd') -Destination $startnet -Force
    Write-SubStep 'startnet.cmd installed'

    # Replace the winpeshl-driven boot with our own entry point so the shell
    # launch order is under our control.
    $winpeshl = Join-Path $MountDir 'Windows/System32/winpeshl.ini'
    if (Test-Path -LiteralPath $winpeshl) {
        Remove-Item -LiteralPath $winpeshl -Force
        Write-SubStep 'removed winpeshl.ini so startnet.cmd runs'
    }

    $peDir = Join-Path $MountDir 'Program Files/MICPE'
    if (-not (Test-Path -LiteralPath $peDir)) {
        New-Item -ItemType Directory -Path $peDir -Force | Out-Null
    }

    foreach ($file in 'PECMD.INI', 'PECMD.EXE') {
        $source = Join-Path $shellSrc $file
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $peDir $file) -Force
            Write-SubStep "$file installed to Program Files/MICPE"
        }
    }

    # Pin-Shortcuts.wcs runs from System32 (next to probe.cmd) so PECMD.INI
    # can CALL it with a space-free path.
    $shortcuts = Join-Path $shellSrc 'Pin-Shortcuts.wcs'
    if (Test-Path -LiteralPath $shortcuts) {
        Copy-Item -LiteralPath $shortcuts -Destination (Join-Path $MountDir 'Windows/System32/Pin-Shortcuts.wcs') -Force
        Write-SubStep 'Pin-Shortcuts.wcs installed to System32'
    }

    # PECMD.EXE is third-party freeware and deliberately not in git. Until a
    # step supplies it (payload asset or CI download, M5/M6), startnet.cmd
    # falls back to the command shell; say so loudly in the build log.
    if (-not (Test-Path -LiteralPath (Join-Path $shellSrc 'PECMD.EXE'))) {
        Write-Warn 'PECMD.EXE is not in src/shell; the image will boot to the cmd fallback until a PECMD binary is supplied'
    }
}

function Install-Runtimes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $InstallWim,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [string] $WimlibPath = 'wimlib-imagex',

        [int] $InstallIndex = 1
    )

    Write-Step 'extracting the WOW64 runtime set'
    $patterns = Read-Whitelist -Path (Join-Path $RepoRoot 'src/filelists/30-runtimes.txt')
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $patterns -WimlibPath $WimlibPath

    $wow64 = Join-Path $MountDir 'Windows/System32/wow64.dll'
    $syswow = Join-Path $MountDir 'Windows/SysWOW64/ntdll.dll'
    $missing = @()
    if (-not (Test-Path -LiteralPath $wow64)) { $missing += 'System32/wow64.dll' }
    if (-not (Test-Path -LiteralPath $syswow)) { $missing += 'SysWOW64/ntdll.dll' }
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "WOW64 runtime is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'WOW64 verified'
}

function Install-Components {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $InstallWim,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [string] $WimlibPath = 'wimlib-imagex',

        [int] $InstallIndex = 1
    )

    Write-Step 'extracting DWM, MMC, input method and handlers'
    $patterns = Read-Whitelist -Path (Join-Path $RepoRoot 'src/filelists/40-components.txt')
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $patterns -WimlibPath $WimlibPath

    $missing = @()
    foreach ($file in 'Windows/System32/dwm.exe', 'Windows/System32/ctfmon.exe', 'Windows/System32/taskmgr.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir $file))) { $missing += $file }
    }
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "Component set is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'DWM, task manager and input components verified'
}

function Get-ImePatterns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Patterns
    )

    # // reuse-check: filter set is plan T11 verbatim (InputMethod / ime /
    # msctf / TextInputFramework / ChsIME / Winlangdb). Pure function so the
    # selection is unit-testable without a real install.wim.
    $filters = @('*InputMethod*', '*ime*', '*msctf*', '*TextInputFramework*', '*ChsIME*', '*Winlangdb*')
    return @($Patterns | Where-Object {
        $candidate = $_
        @($filters | Where-Object { $candidate -like $_ }).Count -gt 0
    })
}

function Install-Ime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $InstallWim,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [string] $WimlibPath = 'wimlib-imagex',

        [int] $InstallIndex = 1
    )

    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    Assert-PathExists -Path $InstallWim -Label 'install.wim'

    Write-Step 'extracting the Microsoft Pinyin input method'
    $all = Read-Whitelist -Path (Join-Path $RepoRoot 'src/filelists/40-components.txt')
    $patterns = @(Get-ImePatterns -Patterns $all)
    if ($patterns.Count -eq 0) {
        throw [System.InvalidOperationException]::new(
            'no IME patterns found in 40-components.txt (expected InputMethod/msctf entries)')
    }
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $patterns -WimlibPath $WimlibPath

    # NOTE (unverified against a real install.wim): the SHARED directory is
    # what plan T11 asserts. If the L2 structural check shows 25H2 lays the
    # IME out differently, re-point this assertion at ChsIME.exe instead of
    # weakening it silently.
    $shared = Join-Path $MountDir 'Windows/System32/InputMethod/SHARED'
    if (-not (Test-Path -LiteralPath $shared)) {
        throw [System.InvalidOperationException]::new(
            "Microsoft Pinyin is incomplete: Windows\\System32\\InputMethod\\SHARED was not extracted from $InstallWim")
    }

    Write-SubStep 'Microsoft Pinyin files verified'
}

function Assert-ImeRegistered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [string] $HiveKey = 'PE-IME'
    )

    $hiveFile = Join-Path $MountDir 'Windows/System32/config/SOFTWARE'
    Assert-PathExists -Path $hiveFile -Label 'SOFTWARE hive'

    Mount-RegistryHive -HiveFile $hiveFile -KeyName $HiveKey
    try {
        $subKey = 'Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload'
        $values = Get-RegistryKeyValues -KeyName $HiveKey -SubKey $subKey
        if ($null -eq $values) {
            throw [System.InvalidOperationException]::new(
                "0804 keyboard preload entry is missing: HKLM\$($HiveKey)\$($subKey) does not exist")
        }

        $hasPinyin = @($values.Values | Where-Object { $_ -match '0804' }).Count -gt 0
        if (-not $hasPinyin) {
            throw [System.InvalidOperationException]::new(
                "0804 keyboard preload entry is missing. Current values: $($values.Values -join ', ')")
        }

        Write-SubStep '0804 (Microsoft Pinyin) preload entry present'
    }
    finally {
        # A failing unload must not mask the real assertion above: warn and
        # continue, matching Invoke-RegistryScript's finally convention.
        try {
            Dismount-RegistryHive -KeyName $HiveKey
        }
        catch {
            Write-Warn "could not unload HKLM\$HiveKey : $($_.Exception.Message)"
        }
    }
}
