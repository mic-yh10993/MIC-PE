#Requires -Version 5.1
<#
.SYNOPSIS
    WimBuilder2 UWP build chain, re-implemented as a MICPE build module.

.DESCRIPTION
    WimBuilder2 builds its UWP desktop by running a fixed sequence of .bat files
    (01-Components/zp-UWPAppX + 01-Components/00-Shell). This module performs the
    same sequence in PowerShell against a mounted MICPE image, reading the file
    lists and registry manifests that tools/Import-Wb2UwpChain.ps1 exported into
    src/uwp/.

    The chain, in wb2's own order:

        1. AppX runtime shims            filelists/10-appx-runtime.txt
        2. AppX system layer             filelists/11-appx-system.txt
        3. AppX service hosts            filelists/20-appx-services.txt
        4. UWP app runtime (2 passes)    filelists/30-appx-apps.txt, 31-*
        5. AppX core / AppRepository     filelists/40-appx-core.txt
        6. Shell components              filelists/41-appx-shellcomponents.txt
        7. UWP task manager              filelists/42-appx-taskmgr.txt
        8. Taskbar / Settings            filelists/50-taskbar.txt, 52-settings.txt
        9. Explorer shell                filelists/60-shell-explorer.txt, 61-*
       10. Service + registry trees      reg/copy/services.txt, reg/copy/keys.txt
       11. Literal values                reg/values/*.reg
       12. Runtime scripts               src/runtime/MICPE -> System32\MICPE

    `51-startmenu.txt` is imported but NOT applied by the default profile: the
    user's WimBuilder2 profile keeps the Shell start menu off.

    Everything the running image needs at boot lives in
    %SystemRoot%\System32\MICPE so a single folder is the whole runtime surface.

.NOTES
    No StartAllBack and no WinXShell binary: the profile is "UWP default, shell
    slot = Explorer", i.e. explorer.exe plus the UWP shell components wb2 copies.
#>

Set-StrictMode -Version Latest

$script:UwpChainManifestName = 'manifest.json'

function Get-UwpChainRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $RepoRoot)

    return (Join-Path $RepoRoot 'src/uwp')
}

function Get-UwpChainManifest {
    <#
        .SYNOPSIS
            Loads src/uwp/manifest.json, which records the WimBuilder2 profile
            this chain reproduces.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $RepoRoot)

    $path = Join-Path (Get-UwpChainRoot -RepoRoot $RepoRoot) $script:UwpChainManifestName
    Assert-PathExists -Path $path -Label 'UWP chain manifest'
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-UwpChainStepList {
    <#
        .SYNOPSIS
            Returns the ordered list of steps the profile enables.

        .DESCRIPTION
            Each entry is a pscustomobject with Kind = 'files' | 'regcopy' |
            'values' | 'runtime' | 'app'. Disabled steps (start menu, when
            manifest.startMenu is false) are filtered out here so callers never
            have to special-case them.

            A step may also carry "requiresFeature": "<flag>", naming a boolean
            at the manifest root (startAllBack, start11). When that flag is
            false the step is skipped, which is how a whole shell replacer -
            files + registrations + support DLLs - turns on with one word.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $RepoRoot)

    $manifest = Get-UwpChainManifest -RepoRoot $RepoRoot
    $root = Get-UwpChainRoot -RepoRoot $RepoRoot

    $steps = [System.Collections.Generic.List[object]]::new()

    foreach ($step in $manifest.steps) {
        # ConvertFrom-Json only materialises the keys a step actually has, and
        # StrictMode turns a missing property into a terminating error, so the
        # optional switches are read through PSObject.
        $enabled = $step.PSObject.Properties['enabled']
        if ($enabled -and $enabled.Value -eq $false) { continue }

        $needsStartMenu = $step.PSObject.Properties['requiresStartMenu']
        if ($needsStartMenu -and $needsStartMenu.Value -eq $true -and -not $manifest.startMenu) { continue }

        # Feature switch: an absent or false manifest flag disables the step.
        $requiresFeature = $step.PSObject.Properties['requiresFeature']
        if ($requiresFeature -and $requiresFeature.Value) {
            $flag = $manifest.PSObject.Properties[$requiresFeature.Value]
            if (-not $flag -or $flag.Value -ne $true) { continue }
        }

        switch ($step.kind) {
            'files' {
                $steps.Add([pscustomobject]@{
                        Kind = 'files'
                        Name = $step.name
                        Path = Join-Path $root ('filelists/' + $step.file)
                    })
            }
            'regcopy' {
                $steps.Add([pscustomobject]@{
                        Kind = 'regcopy'
                        Name = $step.name
                        Services = Join-Path $root ('reg/copy/' + $step.services)
                        Keys = Join-Path $root ('reg/copy/' + $step.keys)
                    })
            }
            'values' {
                $steps.Add([pscustomobject]@{
                        Kind = 'values'
                        Name = $step.name
                        Path = Join-Path $root ('reg/values/' + $step.file)
                    })
            }
            'runtime' {
                $steps.Add([pscustomobject]@{
                        Kind = 'runtime'
                        Name = $step.name
                        Path = Join-Path $RepoRoot $step.dir
                    })
            }
            'app' {
                # An app is the repository's own component format (app/<name>/):
                # an install.bat that copies files, plus the .reg files that
                # belong to that component. Keeping both under app/<name> means
                # a shell replacer can be replaced wholesale without touching
                # this chain.
                $regs = @()
                $regProperty = $step.PSObject.Properties['reg']
                if ($regProperty -and $regProperty.Value) {
                    $regs = @($regProperty.Value | ForEach-Object { Join-Path $RepoRoot $_ })
                }
                $steps.Add([pscustomobject]@{
                        Kind = 'app'
                        Name = $step.name
                        Install = Join-Path $RepoRoot $step.install
                        Reg = $regs
                    })
            }
            default { throw "Unknown UWP chain step kind: $($step.kind)" }
        }
    }

    return $steps.ToArray()
}

# ---------------------------------------------------------------------------
# File lists
# ---------------------------------------------------------------------------

function Test-UwpTreeEntry {
    <#
        .SYNOPSIS
            A trailing slash means "copy the whole directory tree" in the wb2
            lists; wimlib extracts a bare directory path recursively.
    #>
    param([string] $Entry)

    return $Entry.EndsWith('/')
}

function Copy-UwpFileList {
    <#
        .SYNOPSIS
            Applies one src/uwp/filelists/*.txt to a mounted image.

        .DESCRIPTION
            Two passes: whole directory trees individually (rare, and each one is
            worth its own batch so a failure names the directory), then the flat
            file list as one whitelist batch. Missing optional files are skipped
            by wimlib's --nullglob.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallWim,
        [Parameter(Mandatory = $true)][string] $MountDir,
        [Parameter(Mandatory = $true)][string] $ListPath,
        [int] $SourceIndex = 4
    )

    Assert-PathExists -Path $ListPath -Label 'UWP file list'

    $entries = Read-Whitelist -Path $ListPath
    $trees = @($entries | Where-Object { Test-UwpTreeEntry -Entry $_ } |
            ForEach-Object { $_.TrimEnd('/') })
    $files = @($entries | Where-Object { -not (Test-UwpTreeEntry -Entry $_) })

    $name = Split-Path -Leaf $ListPath
    Write-SubStep ("{0}: {1} file(s), {2} tree(s)" -f $name, $files.Count, $trees.Count)

    foreach ($tree in $trees) {
        # Directories are extracted one at a time: a typo in a tree name is a
        # whole subsystem missing, so it must be visible in the log.
        Export-WimFiles -WimPath $InstallWim -Index $SourceIndex `
            -Destination $MountDir -Patterns @($tree)
    }

    if ($files.Count -gt 0) {
        Export-WimFiles -WimPath $InstallWim -Index $SourceIndex `
            -Destination $MountDir -Patterns $files
    }
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

function Split-SourceRegistryKey {
    <#
        .SYNOPSIS
            Splits `HKLM\SYSTEM\ControlSet001\Services\AppXSvc` into the source
            hive file and the path inside that hive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $FullKey)

    $text = $FullKey.Trim()
    if ($text -match '^HKLM\\(.+)$') { $text = $Matches[1] }
    elseif ($text -match '^HKEY_LOCAL_MACHINE\\(.+)$') { $text = $Matches[1] }
    else { throw "Unsupported registry root in '$FullKey' (only HKLM keys are copied)" }

    $parts = $text -split '\\', 2
    if ($parts.Count -lt 2) { throw "Registry key has no subpath: $FullKey" }

    $hive = $parts[0].ToUpperInvariant()
    switch ($hive) {
        'SOFTWARE' { return [pscustomobject]@{ Hive = 'SOFTWARE'; Path = $parts[1] } }
        'SYSTEM' { return [pscustomobject]@{ Hive = 'SYSTEM'; Path = $parts[1] } }
        'DEFAULT' { return [pscustomobject]@{ Hive = 'DEFAULT'; Path = $parts[1] } }
        default { throw "Unsupported hive '$hive' in $FullKey" }
    }
}

function Copy-SourceRegistryTree {
    <#
        .SYNOPSIS
            Copies one key (with all subkeys and values) from the source image's
            hives into the mounted image's hives.

        .DESCRIPTION
            This is wb2's RegCopy, but done through the registry API instead of
            reg.exe's text form (Copy-RegistryKeyTree): values, value kinds,
            subkeys and default values land exactly as the source has them,
            which a hand-written patch cannot promise.

            The text round-trip is deliberately gone. reg.exe wraps a long key
            path at ~100 columns without a continuation backslash, so
            ...\AppModel\SystemAppData\windows.immersivecontrolpanel_... came
            back split across two lines and reg import rejected the file with
            exit 1 (build 2026-11-22 12:33).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FullKey,
        [Parameter(Mandatory = $true)][string] $SourceHiveKey,
        [Parameter(Mandatory = $true)][string] $TargetHiveKey
    )

    $split = Split-SourceRegistryKey -FullKey $FullKey
    $sourcePath = "HKLM\$SourceHiveKey\$($split.Path)"
    $targetPath = "HKLM\$TargetHiveKey\$($split.Path)"

    if (-not (Copy-RegistryKeyTree -SourcePath $sourcePath -TargetPath $targetPath)) {
        Write-Warn "source key missing, skipped: $FullKey"
        return $false
    }
    return $true
}

function Copy-UwpRegistryTrees {
    <#
        .SYNOPSIS
            Applies reg/copy/services.txt and reg/copy/keys.txt.

        .DESCRIPTION
            Mounts the source image's SYSTEM/SOFTWARE hives read-only and the
            target image's hives read-write, then copies each key. Both source
            hives are mounted under PE-SRC-* names so they cannot collide with
            the target's PE-SYS / PE-SOFT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallWim,
        [Parameter(Mandatory = $true)][string] $MountDir,
        [Parameter(Mandatory = $true)][string] $ServicesList,
        [Parameter(Mandatory = $true)][string] $KeysList,
        [int] $SourceIndex = 4,
        [string] $ScratchDir
    )

    Assert-PathExists -Path $ServicesList -Label 'UWP services list'
    Assert-PathExists -Path $KeysList -Label 'UWP keys list'

    if (-not $ScratchDir) { $ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) 'micpe-uwp-src' }
    if (-not (Test-Path -LiteralPath $ScratchDir)) {
        New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
    }

    Export-WimFiles -WimPath $InstallWim -Index $SourceIndex -Destination $ScratchDir `
        -Patterns @('Windows/System32/config/SYSTEM', 'Windows/System32/config/SOFTWARE')

    $srcSys = Join-Path $ScratchDir 'Windows/System32/config/SYSTEM'
    $srcSoft = Join-Path $ScratchDir 'Windows/System32/config/SOFTWARE'
    Assert-PathExists -Path $srcSys -Label 'source SYSTEM hive'
    Assert-PathExists -Path $srcSoft -Label 'source SOFTWARE hive'

    $tgtSys = Join-Path $MountDir 'Windows/System32/config/SYSTEM'
    $tgtSoft = Join-Path $MountDir 'Windows/System32/config/SOFTWARE'
    Assert-PathExists -Path $tgtSys -Label 'target SYSTEM hive'
    Assert-PathExists -Path $tgtSoft -Label 'target SOFTWARE hive'

    Mount-RegistryHive -HiveFile $srcSys -KeyName 'PE-SRC-SYS'
    Mount-RegistryHive -HiveFile $srcSoft -KeyName 'PE-SRC-SOFT'
    Mount-RegistryHive -HiveFile $tgtSys -KeyName 'PE-SYS'
    Mount-RegistryHive -HiveFile $tgtSoft -KeyName 'PE-SOFT'

    $copied = 0
    $skipped = 0
    try {
        $jobs = [System.Collections.Generic.List[object]]::new()

        foreach ($service in (Read-Whitelist -Path $ServicesList)) {
            $jobs.Add([pscustomobject]@{
                    Key = "HKLM\SYSTEM\ControlSet001\Services\$service"
                    SourceHive = 'SYSTEM'; SourceKey = 'PE-SRC-SYS'; TargetKey = 'PE-SYS'
                })
        }
        foreach ($key in (Read-Whitelist -Path $KeysList)) {
            $split = Split-SourceRegistryKey -FullKey $key
            $sourceKey = if ($split.Hive -eq 'SYSTEM') { 'PE-SRC-SYS' } else { 'PE-SRC-SOFT' }
            $targetKey = if ($split.Hive -eq 'SYSTEM') { 'PE-SYS' } else { 'PE-SOFT' }
            $jobs.Add([pscustomobject]@{
                    Key = $key; SourceHive = $split.Hive; SourceKey = $sourceKey; TargetKey = $targetKey
                })
        }

        Write-SubStep ("copying {0} registry trees" -f $jobs.Count)
        Reset-RegistryCopyDenied
        foreach ($job in $jobs) {
            if (Copy-SourceRegistryTree -FullKey $job.Key `
                    -SourceHiveKey $job.SourceKey -TargetHiveKey $job.TargetKey) {
                $copied++
            }
            else { $skipped++ }
        }
    }
    finally {
        foreach ($name in 'PE-SYS', 'PE-SOFT', 'PE-SRC-SYS', 'PE-SRC-SOFT') {
            if (Test-RegistryHiveMounted -KeyName $name) { Dismount-RegistryHive -KeyName $name }
        }
    }

    Write-SubStep ("registry trees copied: {0}, missing in source: {1}" -f $copied, $skipped)

    # TrustedInstaller-owned keys are repaired in place by Copy-RegistryKeyTree.
    # Whatever still refused access is listed here: the copy keeps going, but a
    # build must never hide a skipped key.
    $denied = @(Get-RegistryCopyDenied)
    if ($denied.Count -gt 0) {
        Write-Warn ("{0} key path(s) stayed read-only: {1}" -f $denied.Count, ($denied -join '; '))
    }
    $unreadable = @(Get-RegistryCopyUnreadable)
    if ($unreadable.Count -gt 0) {
        Write-Warn ("{0} source subtree(s) unreadable: {1}" -f $unreadable.Count, ($unreadable -join '; '))
    }
}

# ---------------------------------------------------------------------------
# Integration
# ---------------------------------------------------------------------------

function Copy-UwpTreeTo {
    <#
        .SYNOPSIS
            Copies a directory tree into the mounted image, creating parents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination,
        [string[]] $Exclude = @()
    )

    Assert-PathExists -Path $Source -Label 'payload source'

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $files = @(Get-ChildItem -LiteralPath $Source -File -Recurse |
            Where-Object { $Exclude -notcontains $_.Name })
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\', '/')
        $dest = Join-Path $Destination $relative
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
    }

    return $files.Count
}

function Set-UwpBinaryString {
    <#
        .SYNOPSIS
            Replaces a UTF-16LE string inside a binary, the way wb2's binmay does.

        .DESCRIPTION
            `binmay.exe -u file -s u:MiniNT -r u:NiniNT` rewrites the PE-check
            marker in two DLLs so the component stops treating the image as
            WinPE. The replacement must be the same length, otherwise every
            offset stored in the file would move.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Find,
        [Parameter(Mandatory = $true)][string] $Replace
    )

    if ($Find.Length -ne $Replace.Length) {
        throw "binary patch needs equal lengths: '$Find' -> '$Replace'"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warn "binary patch target missing, skipped: $Path"
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $needle = [System.Text.Encoding]::Unicode.GetBytes($Find)
    $replacement = [System.Text.Encoding]::Unicode.GetBytes($Replace)

    $hits = 0
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if (-not $match) { continue }
        for ($j = 0; $j -lt $replacement.Length; $j++) {
            $bytes[$i + $j] = $replacement[$j]
        }
        $hits++
        $i += $needle.Length - 1
    }

    if ($hits -gt 0) {
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }
    return $hits -gt 0
}

function Grant-FolderWriteAccess {
    <#
        .SYNOPSIS
            Makes sure the build account can write into a folder of the image.

        .DESCRIPTION
            A few folders arrive from DISM with an ACL that grants only
            TrustedInstaller, and Copy-Item then fails with "Access to the path
            ... is denied" - which is exactly what happened to the AppRepository
            database, because that folder already exists in the source image and
            the .srd file has to land inside it.

            takeown / icacls are used rather than a .NET FileSecurity object:
            changing the owner needs SeTakeOwnershipPrivilege, which the
            elevated build token already holds and the cmd tools enable by
            themselves.

            The ACE goes to BUILTIN\Administrators, never to "Everyone": the
            image keeps a normal Windows ACL, with one extra entry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $isFile = -not (Test-Path -LiteralPath $Path -PathType Container)
    $null = & takeown.exe /F $Path /A 2>&1
    if ($isFile) {
        $null = & icacls.exe $Path /Grant '*S-1-5-32-544:F' /C 2>&1
        $null = & attrib.exe -R $Path 2>&1
    }
    else {
        $null = & icacls.exe $Path /Grant '*S-1-5-32-544:(OI)(CI)F' /T /C 2>&1

        # A leftover read-only attribute fails the copy in the same way.
        $null = & attrib.exe -R $Path /S /D 2>&1
    }
}

function Invoke-AppInstaller {
    <#
        .SYNOPSIS
            Runs one app/<name>/install.bat against the mounted image.

        .DESCRIPTION
            app/ is this repository's component format: the program files plus
            an install.bat that copies them into an already mounted image. The
            script is a batch file on purpose - it is the same one a component
            author can run by hand from a build shell, so there is no second,
            PowerShell-only code path that could drift from it.

            Contract (see app/README.md): install.bat <mount-dir> <repo-root>,
            idempotent, exit 0 on success. The exit code is checked, and its
            stdout is forwarded line by line so a failed xcopy is readable in
            the build log instead of a silent "step finished".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallBat,
        [Parameter(Mandatory = $true)][string] $MountDir,
        [Parameter(Mandatory = $true)][string] $RepoRoot
    )

    Assert-PathExists -Path $InstallBat -Label 'app installer'
    if (-not (Test-Path -LiteralPath $MountDir)) {
        throw "app installer needs a mounted image: $MountDir"
    }

    $command = '"{0}" "{1}" "{2}"' -f $InstallBat, $MountDir, $RepoRoot
    $output = & cmd.exe /c $command 2>&1
    foreach ($line in @($output)) {
        if ("$line".Trim()) { Write-SubStep ("  {0}" -f $line) }
    }
    if ($LASTEXITCODE -ne 0) {
        throw ("app installer failed (exit {0}): {1}" -f $LASTEXITCODE, $InstallBat)
    }
    Write-SubStep ("app installed: {0}" -f (Split-Path -Leaf (Split-Path -Parent $InstallBat)))
}

function Install-MicpeRuntime {
    <#
        .SYNOPSIS
            Installs this project's boot chain and shell payload into the image.

        .DESCRIPTION
            Everything the image executes at boot lives in src/runtime/MICPE and
            is copied to %SystemRoot%\System32\MICPE as-is, so the folder in the
            repository and the folder in the image are the same tree:

                startnet.cmd        -> System32\startnet.cmd   (winpeshl entry)
                phases\*.cmd        -> System32\MICPE\phases
                hooks\<phase>\*.cmd -> System32\MICPE\hooks
                uwp-diag.cmd        -> System32\MICPE

            Two payloads are data, not scripts, and are installed next to it:

                src/uwp/payload/winshell/      -> Program Files\WinXShell
                src/uwp/payload/apprepository/ -> ProgramData\...\AppRepository

            WinXShell is not the shell in this profile (Winlogon Shell is
            explorer.exe). The boot chain uses it to hide the console, to wait
            for the taskbar and as the fallback shell. The AppRepository
            database is what the StateRepository service opens before any UWP
            package can activate.

            The boot chain is this project's own code - no PECMD, no
            WimBuilder2 runner, no PEMaterial tree. Editing a phase file here
            and rebuilding is the whole customisation loop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $MountDir,
        [Parameter(Mandatory = $true)][string] $SourceDir,
        [Parameter(Mandatory = $true)][string] $RepoRoot
    )

    Assert-PathExists -Path $SourceDir -Label 'MICPE runtime folder'
    $payload = Join-Path $RepoRoot 'src/uwp/payload'

    # --- 1. runtime scripts ---------------------------------------------------
    # The whole tree goes to System32\MICPE, phases\ and hooks\ included, so a
    # path printed in a log always matches a path in the repository.
    $micpeDst = Join-Path $MountDir 'Windows/System32/MICPE'
    $count = Copy-UwpTreeTo -Source $SourceDir -Destination $micpeDst
    Write-SubStep ("runtime -> System32\MICPE: {0} file(s)" -f $count)

    # --- 2. the one file that cannot live there -------------------------------
    # winpeshl.exe runs %SystemRoot%\System32\startnet.cmd by name. It stays a
    # thin sequencer; every phase it calls lives in MICPE.
    $startnetSrc = Join-Path $SourceDir 'startnet.cmd'
    Assert-PathExists -Path $startnetSrc -Label 'startnet.cmd'
    Copy-Item -LiteralPath $startnetSrc `
        -Destination (Join-Path $MountDir 'Windows/System32/startnet.cmd') -Force
    Write-SubStep 'startnet.cmd -> System32 (boot entry)'

    # winpeshl.ini wins over startnet.cmd and would boot to a bare prompt.
    $winpeshlIni = Join-Path $MountDir 'Windows/System32/winpeshl.ini'
    if (Test-Path -LiteralPath $winpeshlIni) {
        Remove-Item -LiteralPath $winpeshlIni -Force
        Write-SubStep 'winpeshl.ini removed (startnet.cmd owns the boot)'
    }

    # --- 3. WinXShell payload -------------------------------------------------
    $winshellSrc = Join-Path $payload 'winshell'
    if (Test-Path -LiteralPath $winshellSrc) {
        $winshellDst = Join-Path $MountDir 'Program Files/WinXShell'
        $count = Copy-UwpTreeTo -Source $winshellSrc -Destination $winshellDst

        # The payload ships arch-suffixed binaries and a per-language config;
        # rename the x64 ones and make WinXShell.jcfg the active config.
        foreach ($pair in @(@('WinXShell_x64.exe', 'WinXShell.exe'),
                            @('WinXShellC_x64.exe', 'WinXShellC.exe'))) {
            $from = Join-Path $winshellDst $pair[0]
            if (Test-Path -LiteralPath $from) {
                Move-Item -LiteralPath $from -Destination (Join-Path $winshellDst $pair[1]) -Force
            }
        }
        Get-ChildItem -LiteralPath $winshellDst -Filter 'WinXShell*_*.exe' -ErrorAction SilentlyContinue |
            Remove-Item -Force
        $jcfg = Join-Path $winshellDst 'WinXShell.jcfg'
        if (-not (Test-Path -LiteralPath $jcfg)) {
            $cn = Join-Path $winshellDst 'WinXShell.zh-CN.cfg'
            if (Test-Path -LiteralPath $cn) {
                Copy-Item -LiteralPath $cn -Destination $jcfg -Force
            }
        }
        Write-SubStep ("WinXShell -> Program Files\WinXShell: {0} file(s)" -f $count)
    }
    else {
        Write-Warn 'src/uwp/payload/winshell is missing; the console will stay visible'
    }

    # --- 4. StateRepository database -----------------------------------------
    # Without these two files the StateRepository service cannot start and no
    # UWP package activates, which takes explorer (XAML taskbar) with it.
    $appRepo = Join-Path $MountDir 'ProgramData/Microsoft/Windows/AppRepository'
    if (-not (Test-Path -LiteralPath $appRepo)) {
        New-Item -ItemType Directory -Path $appRepo -Force | Out-Null
    }
    # Owned by TrustedInstaller in the source image: without taking it over the
    # copy below dies with "Access denied".
    Grant-FolderWriteAccess -Path $appRepo

    $srd = @(Get-ChildItem -LiteralPath (Join-Path $payload 'apprepository') -Filter '*.srd' -ErrorAction SilentlyContinue)
    foreach ($file in $srd) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $appRepo $file.Name) -Force
    }
    Write-SubStep ("AppRepository -> {0} .srd file(s)" -f $srd.Count)
    if ($srd.Count -eq 0) {
        Write-Warn 'no .srd in src/uwp/payload/apprepository; StateRepository will not start'
    }

    # --- 5. WinPE check patches ----------------------------------------------
    # Both DLLs branch on the wide string "MiniNT" to decide "this is WinPE".
    # The UWP stack takes its reduced WinPE path while that answer is yes - the
    # credential dialog and the text input service both do. Same length, same
    # offset, so the patch is a single string replacement.
    $patched = 0
    foreach ($name in 'Windows.UI.CredDialogController.dll', 'InputService.dll') {
        $dll = Join-Path $MountDir "Windows/System32/$name"
        # Both files belong to TrustedInstaller in the source image, so the
        # in-place write below needs the ownership change first.
        if (Test-Path -LiteralPath $dll) { Grant-FolderWriteAccess -Path $dll }
        if (Set-UwpBinaryString -Path $dll -Find 'MiniNT' -Replace 'NiniNT') { $patched++ }
    }
    Write-SubStep ("WinPE marker patched (MiniNT -> NiniNT): {0}/2 DLL(s)" -f $patched)
}

function Measure-UwpChainCompleteness {
    <#
        .SYNOPSIS
            Reports, per imported file list, how many entries actually landed.

        .DESCRIPTION
            The wb2 lists are the specification; the image is the result. A list
            entry that resolves to nothing is either a version-gated file whose
            guard the importer evaluated wrongly (how mdmregistration.dll went
            missing and stopped explorer.exe from loading at all) or a path that
            only exists on some media. Neither is visible from "the step ran",
            so every applied list gets a present/total count.

            Missing entries are reported, not thrown: wb2's AddFiles uses
            wildcard patterns and optional language files, so a zero count is
            normal for them. The required list below is what must exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $MountDir,
        [Parameter(Mandatory = $true)][string] $RepoRoot
    )

    $steps = @(Get-UwpChainStepList -RepoRoot $RepoRoot | Where-Object { $_.Kind -eq 'files' })
    $totalPresent = 0
    $totalEntries = 0

    foreach ($step in $steps) {
        $entries = @(Read-Whitelist -Path $step.Path)
        $present = 0
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $entries) {
            $path = Join-Path $MountDir ($entry.TrimEnd('/') -replace '/', '\')
            # wb2 lists mix literal paths with wildcard patterns
            # (`CatRoot\...\Client-Desktop-Required-Package*.cat`,
            # `Appx*.*`, `??-??\explorer.exe.mui`); wimlib expands those, so the
            # check has to as well or every wildcard reads as a missing file.
            $found = if ($entry -match '[*?]') {
                [bool] (Test-Path -Path $path)
            }
            else {
                Test-Path -LiteralPath $path
            }
            if ($found) { $present++ } else { $missing.Add($entry) }
        }
        $totalPresent += $present
        $totalEntries += $entries.Count

        $name = Split-Path -Leaf $step.Path
        if ($missing.Count -eq 0) {
            Write-SubStep ("{0}: {1}/{1} present" -f $name, $present)
        }
        else {
            Write-SubStep ("{0}: {1}/{2} present, {3} not in source" -f $name, $present, $entries.Count, $missing.Count)
            $head = @($missing | Select-Object -First 8)
            Write-SubStep ("  absent: {0}{1}" -f ($head -join ', '), $(if ($missing.Count -gt $head.Count) { ' ...' } else { '' }))
        }
    }

    Write-SubStep ("file lists: {0}/{1} entries landed" -f $totalPresent, $totalEntries)

    # These are not optional: explorer.exe imports MDMRegistration.dll
    # statically, and the shell DLLs are what the UWP taskbar loads. Asserting
    # them here turns a black desktop into a build failure with a file name.
    $required = @(
        'Windows/explorer.exe'
        'Windows/System32/MDMRegistration.dll'
        'Windows/System32/shell32.dll'
        'Windows/System32/twinui.pcshell.dll'
        'Windows/System32/Windows.UI.Xaml.dll'
        'Windows/System32/CoreMessaging.dll'
    )
    foreach ($rel in $required) {
        Assert-PathExists -Path (Join-Path $MountDir ($rel -replace '/', '\')) -Label "shell prerequisite $rel"
    }
    Write-SubStep 'shell prerequisites present'
}

function Assert-UwpBootChain {
    <#
        .SYNOPSIS
            Fails the build when the image's boot chain is not this project's.

        .DESCRIPTION
            The image boots through System32\startnet.cmd, which sequences the
            phases in System32\MICPE\phases: osinit -> preshell -> runshell ->
            postshell. Every piece that sequence calls has to exist, otherwise
            the image falls back to a bare cmd prompt or a black desktop with
            nothing to read.

            Checked on the installed files rather than on the repository,
            because the failure mode is always "the build wrote something else".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $MountDir)

    $startnet = Join-Path $MountDir 'Windows/System32/startnet.cmd'
    Assert-PathExists -Path $startnet -Label 'System32\startnet.cmd'
    $text = Get-Content -LiteralPath $startnet -Raw

    # Comments may mention the old chains (that is where the history lives);
    # only executable lines count.
    $code = (@($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*(rem\b|::)' }) -join "`n")

    foreach ($phase in '10-osinit', '20-preshell', '30-runshell', '40-postshell') {
        if ($code -notmatch [regex]::Escape("phases\$phase.cmd")) {
            throw [System.InvalidOperationException]::new(
                "System32\startnet.cmd does not call phases\$phase.cmd - the boot sequence is incomplete")
        }
    }
    if ($code -match 'PECMD') {
        throw [System.InvalidOperationException]::new(
            'System32\startnet.cmd references PECMD - this profile has no PECMD in its chain')
    }
    if ($code -match 'PEStartupMain|PEMaterial') {
        throw [System.InvalidOperationException]::new(
            'System32\startnet.cmd still points at the WimBuilder2 PEMaterial tree - the image must run its own chain')
    }

    $required = @(
        'Windows/System32/MICPE/phases/10-osinit.cmd'
        'Windows/System32/MICPE/phases/20-preshell.cmd'
        'Windows/System32/MICPE/phases/30-runshell.cmd'
        'Windows/System32/MICPE/phases/40-postshell.cmd'
        'Windows/System32/MICPE/uwp-diag.cmd'
        'Windows/System32/MICPE/uwp-start-shell.cmd'
        'Program Files/WinXShell/WinXShell.exe'
        'ProgramData/Microsoft/Windows/AppRepository/StateRepository-Machine.srd'
        'Windows/explorer.exe'
    )
    foreach ($rel in $required) {
        Assert-PathExists -Path (Join-Path $MountDir ($rel -replace '/', '\')) -Label "boot chain $rel"
    }

    $winpeshlIni = Join-Path $MountDir 'Windows/System32/winpeshl.ini'
    if (Test-Path -LiteralPath $winpeshlIni) {
        throw [System.InvalidOperationException]::new(
            'winpeshl.ini is present and overrides startnet.cmd; the boot entry must be startnet.cmd')
    }

    # The old copy of the chain must be gone, or a stale tree would sit next to
    # the live one and confuse every later debugging session.
    if (Test-Path -LiteralPath (Join-Path $MountDir 'PEMaterial')) {
        Write-Warn 'X:\PEMaterial exists in the image; the boot chain no longer uses it'
    }

    Write-SubStep 'boot chain: startnet.cmd -> MICPE\phases -> explorer.exe'
}

function Assert-UwpChainReady {
    <#
        .SYNOPSIS
            Structural check that the chain landed: the deployment stack, the
            shell, the runtime folder and the two service keys wb2 depends on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $MountDir)

    $required = @(
        'Windows/System32/AppXDeploymentClient.dll'
        'Windows/System32/AppXDeploymentServer.dll'
        'Windows/System32/Windows.UI.Xaml.dll'
        'Windows/System32/MICPE'
    )

    $missing = @()
    foreach ($rel in $required) {
        $path = Join-Path $MountDir $rel
        if (-not (Test-Path -LiteralPath $path)) { $missing += $rel }
    }

    # Explorer is optional: the start menu / shell profile may legitimately
    # leave it to the WinXShell slot instead.
    $explorer = Join-Path $MountDir 'Windows/explorer.exe'
    if (-not (Test-Path -LiteralPath $explorer)) {
        Write-Warn 'explorer.exe not present - shell slot will fall back to the payload shell'
    }

    # LogonUI belongs to the native-logon path (src/filelists/70-logon.txt, which
    # the Explorer step applies only with -NativeLogonExperiment). This chain
    # boots straight into the shell, so LogonUI is absent by design; asserting it
    # here made every wb2 build stop on a file the chain never asked for.
    $logonUi = Join-Path $MountDir 'Windows/System32/LogonUI.exe'
    if (-not (Test-Path -LiteralPath $logonUi)) {
        Write-SubStep 'LogonUI.exe absent - shell-only image, no interactive logon'
    }

    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            'UWP chain is incomplete, missing: ' + ($missing -join ', '))
    }

    $sysHive = Join-Path $MountDir 'Windows/System32/config/SYSTEM'
    Mount-RegistryHive -HiveFile $sysHive -KeyName 'PE-SYS'
    try {
        foreach ($service in 'AppXSvc', 'AppReadiness', 'ClipSVC') {
            $null = & reg.exe query "HKLM\PE-SYS\ControlSet001\Services\$service" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw [System.InvalidOperationException]::new("service key not copied: $service")
            }
        }
    }
    finally {
        if (Test-RegistryHiveMounted -KeyName 'PE-SYS') { Dismount-RegistryHive -KeyName 'PE-SYS' }
    }
}

function Install-WbUwpChain {
    <#
        .SYNOPSIS
            Runs the whole WimBuilder2 UWP chain against a mounted image.

        .EXAMPLE
            Install-WbUwpChain -InstallWim E:\ws\base\install.wim -MountDir E:\ws\mount -RepoRoot .
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $InstallWim,
        [Parameter(Mandatory = $true)][string] $MountDir,
        [Parameter(Mandatory = $true)][string] $RepoRoot,
        [int] $SourceIndex = 4,
        [string] $ScratchDir
    )

    $manifest = Get-UwpChainManifest -RepoRoot $RepoRoot
    $steps = Get-UwpChainStepList -RepoRoot $RepoRoot

    Write-Step ("UWP chain: profile '{0}' (shell={1}, start menu={2}, UWP components={3})" -f
        $manifest.profile, $manifest.shell, $manifest.startMenu, $manifest.uwpComponents)

    foreach ($step in $steps) {
        Write-SubStep ("step: {0} [{1}]" -f $step.Name, $step.Kind)
        switch ($step.Kind) {
            'files' {
                Copy-UwpFileList -InstallWim $InstallWim -MountDir $MountDir `
                    -ListPath $step.Path -SourceIndex $SourceIndex
            }
            'regcopy' {
                Copy-UwpRegistryTrees -InstallWim $InstallWim -MountDir $MountDir `
                    -ServicesList $step.Services -KeysList $step.Keys `
                    -SourceIndex $SourceIndex -ScratchDir $ScratchDir
            }
            'values' {
                Invoke-RegistryScript -MountDir $MountDir -RegFiles @($step.Path)
            }
            'runtime' {
                Install-MicpeRuntime -MountDir $MountDir -SourceDir $step.Path -RepoRoot $RepoRoot
            }
            'app' {
                Invoke-AppInstaller -InstallBat $step.Install -MountDir $MountDir -RepoRoot $RepoRoot
                if ($step.Reg.Count -gt 0) {
                    Invoke-RegistryScript -MountDir $MountDir -RegFiles $step.Reg
                }
            }
        }
    }

    Assert-UwpChainReady -MountDir $MountDir
    Measure-UwpChainCompleteness -MountDir $MountDir -RepoRoot $RepoRoot
    Assert-UwpBootChain -MountDir $MountDir
    Write-Step 'UWP chain complete'
}
