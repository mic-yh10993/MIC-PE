#Requires -Version 7.0
<#
.SYNOPSIS
    WIM handling: whitelist parsing, mounting, extraction, size assertion,
    boot-image selection.
.DESCRIPTION
    The MICPE build assembles its PE by copying a whitelisted set of files out of
    install.wim. wimlib-imagex does that far faster than DISM, and it understands
    wildcards, so the whitelists stay short. DISM is used only for mounting.
    wimlib-imagex also sets the WIM boot image: the UUP media's boot.wim boots
    image 2 (Windows Setup) unless told otherwise, while every build step
    customises image 1 (Windows PE), so the build must point the boot image
    at 1 before packaging, or winload starts Setup and the probe never runs.
#>

$script:BootWimMaxBytes = 3GB
$script:WimExtractBatchSize = 50

function ConvertTo-WimPathPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Line
    )

    $text = $Line.Trim()
    if (-not $text) { return $null }
    if ($text.StartsWith(';') -or $text.StartsWith('#')) { return $null }
    if ($text.StartsWith('\')) { $text = $text.Substring(1) }
    $text = $text.TrimEnd()
    if (-not $text) { return $null }
    return $text
}

function Read-Whitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Assert-PathExists -Path $Path -Label 'Whitelist'

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $pattern = ConvertTo-WimPathPattern -Line $line
        if ($null -eq $pattern) { continue }
        if ($seen.Add($pattern)) { $result.Add($pattern) }
    }

    return $result.ToArray()
}

function Assert-BootWimSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath
    )

    Assert-FileSize -Path $WimPath -MaxBytes $script:BootWimMaxBytes -Label 'boot.wim'
}

function Mount-WimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [int] $Index = 1,

        [Parameter(Mandatory = $true)]
        [string] $MountDir
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    if (-not (Test-Path -LiteralPath $MountDir)) {
        New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
    }

    Write-SubStep "mounting $WimPath (index $Index) -> $MountDir"
    & dism.exe /English /Mount-Image "/ImageFile:$WimPath" "/Index:$Index" "/MountDir:$MountDir" /Optimize |
        Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "dism /Mount-Image failed with exit code $LASTEXITCODE for $WimPath"
}

function Dismount-WimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [switch] $Commit
    )

    $args = @('/English', '/Unmount-Image', "/MountDir:$MountDir")
    if ($Commit) { $args += '/Commit' } else { $args += '/Discard' }

    Write-SubStep ("{0} {1}" -f ($(if ($Commit) { 'committing' } else { 'discarding' })), $MountDir)
    & dism.exe @args | Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "dism /Unmount-Image failed with exit code $LASTEXITCODE for $MountDir"
}

function Export-WimFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [int] $Index = 1,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Patterns,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    if ($Patterns.Count -eq 0) {
        Write-Warn 'no extraction patterns supplied'
        return
    }

    $batchIndex = 0
    for ($offset = 0; $offset -lt $Patterns.Count; $offset += $script:WimExtractBatchSize) {
        $batchIndex++
        $end = [Math]::Min($offset + $script:WimExtractBatchSize - 1, $Patterns.Count - 1)
        $batch = $Patterns[$offset..$end]

        Write-SubStep ("extracting batch {0} ({1} pattern(s))" -f $batchIndex, $batch.Count)
        # The batch is whitelist patterns passed as PATH arguments, and
        # wimlib flattens PATH arguments into the destination by default;
        # --preserve-dir-structure keeps the archive paths the callers
        # assert on (Windows\explorer.exe and friends must land nested,
        # not at the destination root).
        # --nullglob: whitelists are shared across Windows builds, but a given
        # source image may not carry every listed path. E.g. the build 26300
        # install.wim has no Windows\System32\query.exe (only query.dll), and
        # wimlib otherwise aborts the whole batch with exit 49, leaving
        # critical files later in the same batch (dwm.exe, taskmgr.exe)
        # unextracted. Missing optional entries must not fail the batch;
        # critical files are still enforced by explicit Test-Path checks in
        # the Install-* callers.
        # $LASTEXITCODE is only set by native commands; the Pester fake is
        # a script, so it never sets the caller's value. Initialise it so
        # the check below also works in a fresh session (a real wimlib
        # overwrites it with its own exit code).
        $LASTEXITCODE = 0
        & $WimlibPath extract $WimPath $Index @batch "--dest-dir=$Destination" '--preserve-dir-structure' '--nullglob' | Out-Host

        if ($LASTEXITCODE -ne 0) {
            $preview = ($batch | Select-Object -First 3) -join ', '
            throw [System.InvalidOperationException]::new(
                "wimlib-imagex extract failed with exit code $LASTEXITCODE in batch $batchIndex starting with: $preview")
        }
    }
}

function Get-WimBootIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    # $LASTEXITCODE is only set by native commands; the Pester fake is a
    # script, so it never sets the caller's value. Initialise it so the
    # check below also works in a fresh session (a real wimlib overwrites
    # it with its own exit code).
    $LASTEXITCODE = 0
    $info = & $WimlibPath info $WimPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "wimlib-imagex info failed with exit code $LASTEXITCODE for $WimPath")
    }

    $match = [regex]::Match(($info -join "`n"), 'Boot Index:\s*(\d+)')
    if (-not $match.Success) {
        throw [System.InvalidOperationException]::new(
            "wimlib-imagex info output for $WimPath has no 'Boot Index' line")
    }
    return [int]$match.Groups[1].Value
}

function Set-WimBootIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [Parameter(Mandatory = $true)]
        [int] $Index,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    # wimlib-imagex info --boot rewrites only the WIM header's boot-index
    # field; it does not recompress or touch any image.
    Write-SubStep "setting boot image of $WimPath to index $Index"
    # $LASTEXITCODE is only set by native commands; the Pester fake is a
    # script, so it never sets the caller's value (see Get-WimBootIndex).
    $LASTEXITCODE = 0
    & $WimlibPath info $WimPath --boot $Index | Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "wimlib-imagex info --boot failed with exit code $LASTEXITCODE for $WimPath"
}

function Copy-SignedHostToolsToSystem32 {
    <#
    .SYNOPSIS
        Copy Microsoft-signed host System32 tools into the PE image.

    .DESCRIPTION
        The 26300 install.wim no longer exposes tsdiscon.exe / tscon.exe at
        Windows\System32\. Their WinSxS copies are DCS-compressed: wimlib
        extracts an ~11 KB compressed stream, not a loadable PE image. Use
        the build host's own System32 binaries, but only after verifying a
        valid Microsoft Authenticode signature, and fail the build if the
        signature check does not pass. The native logon bootstrap calls these
        by bare System32 name, so --nullglob on the whitelist must not be
        allowed to skip them silently.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Names,

        [string] $SourceSystemDir = (Join-Path $env:windir 'System32')
    )

    Assert-PathExists -Path $MountDir -Label 'mounted PE directory'
    Assert-PathExists -Path $SourceSystemDir -Label 'host System32 directory'

    foreach ($name in $Names) {
        $source = Join-Path $SourceSystemDir $name
        Assert-PathExists -Path $source -Label "host tool $name"

        $signature = Get-AuthenticodeSignature -LiteralPath $source
        $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne 'Valid' -or $signer -notmatch 'Microsoft') {
            throw [System.InvalidOperationException]::new(
                "$source is not a valid Microsoft-signed binary (status=$($signature.Status), signer='$signer')")
        }

        $destination = Join-Path $MountDir ("Windows\System32\{0}" -f $name)
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Assert-PathExists -Path $destination -Label "System32\$name"
        Write-SubStep "copied Microsoft-signed $name -> System32 (signer: $signer)"
    }
}

function Install-NativeLogonAssets {
    <#
    .SYNOPSIS
        Install the WimBuilder2-verified account/security assets required for
        a real interactive logon of the built-in Administrator (RID 500).

    .DESCRIPTION
        The native logon chain (startnet-native-logon.cmd) authenticates the
        built-in Administrator through LSA/SAM at runtime. Hand-writing a few
        Winlogon values in the SOFTWARE hive is NOT enough: the same image boots
        a working native UWP desktop under WimBuilder2 because that chain also:

          1. enables the RID-500 account via `secedit /configure` with an
             unattend.inf ([System Access] EnableAdminAccount=1). Without this
             the account may stay disabled and AutoAdminLogon silently fails.
          2. grants Administrator the SYSTEM-class token privileges
             (SeAssignPrimaryTokenPrivilege, SeImpersonatePrivilege,
             SeCreateTokenPrivilege, ...) through LSAgetRights.exe. Missing
             these is what makes a shell launched in the new session fail with
             "referencing a token that does not exist" (STATUS_NO_SUCH_LOGON_SESSION).
          3. ships UsrClass.dat in the Default/Administrator profiles, which
             22621+ requires or the RID-500 profile cannot be created.

        All three donor files are checked into assets/logon/ (copied from the
        WimBuilder2 distribution supplied for this project). This function
        places them at the exact paths the runtime chain expects, so the build
        stays self-contained and reproducible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [string] $SevenZip = '7z'
    )

    Assert-PathExists -Path $MountDir -Label 'mounted PE directory'
    $assetDir = Join-Path $RepoRoot 'assets\logon'
    Assert-PathExists -Path $assetDir -Label 'native logon asset directory'

    # 1. LSAgetRights.exe -> System32. Used by the runtime chain to add the
    #    token privileges the authenticated Administrator session needs.
    $lsaSrc = Join-Path $assetDir 'LSAgetRights_x64.exe'
    Assert-PathExists -Path $lsaSrc -Label 'LSAgetRights asset'
    $lsaDst = Join-Path $MountDir 'Windows\System32\LSAgetRights.exe'
    Copy-Item -LiteralPath $lsaSrc -Destination $lsaDst -Force
    Assert-PathExists -Path $lsaDst -Label 'System32\LSAgetRights.exe'
    Write-SubStep 'installed LSAgetRights.exe -> System32'

    # 2. Expand Security.cab into Windows\Security so runtime secedit can
    #    apply Templates\unattend.inf against Database\unattend.sdb.
    $cab = Join-Path $assetDir 'Security.cab'
    Assert-PathExists -Path $cab -Label 'Security.cab asset'
    $secDir = Join-Path $MountDir 'Windows\Security'
    if (-not (Test-Path -LiteralPath $secDir)) {
        New-Item -ItemType Directory -Path $secDir -Force | Out-Null
    }
    $null = & $SevenZip x $cab ("-o{0}" -f $secDir) -y 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "7z failed to expand Security.cab into $secDir (exit $LASTEXITCODE)"
    foreach ($required in @('Templates\unattend.inf', 'Database\unattend.sdb')) {
        Assert-PathExists -Path (Join-Path $secDir $required) -Label "Windows\Security\$required"
    }
    # secedit writes its log here at runtime; create the folder at build time
    # so the runtime chain never has to create directories in the live image.
    $logDir = Join-Path $secDir 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Write-SubStep 'expanded Security.cab -> Windows\Security (unattend.inf + unattend.sdb)'

    # 2b. Overlay OUR template on top of the donor one.
    #     The WimBuilder2 template only carries [System Access]
    #     EnableAdminAccount=1. A programmatic logon (runas ->
    #     CreateProcessWithLogonW, serviced by seclogon) additionally needs
    #     SeInteractiveLogonRight for the account AND LimitBlankPasswordUse=0,
    #     otherwise the blank-password Administrator is refused with
    #     "logon failure: user name or password is incorrect" even though the
    #     account is enabled. The donor Database\unattend.sdb is kept as-is:
    #     secedit rewrites it from the template on every /configure.
    $infOverride = Join-Path $assetDir 'unattend-logon.inf'
    Assert-PathExists -Path $infOverride -Label 'unattend-logon.inf asset'
    $infDst = Join-Path $secDir 'Templates\unattend.inf'
    Copy-Item -LiteralPath $infOverride -Destination $infDst -Force
    Assert-PathExists -Path $infDst -Label 'Windows\Security\Templates\unattend.inf'
    Write-SubStep 'overlaid unattend.inf with the logon-rights template'

    # 3. UsrClass.dat -> both Default and Administrator profile locations.
    #    WimBuilder2 copies it to Default; 22621+ cannot create the RID-500
    #    profile without it. Pre-seeding Administrator too makes the precreate
    #    path deterministic even when Winlogon clones the profile on first logon.
    $usrSrc = Join-Path $assetDir 'UsrClass.dat'
    Assert-PathExists -Path $usrSrc -Label 'UsrClass.dat asset'
    $usrTargets = @(
        'Users\Default\AppData\Local\Microsoft\Windows\UsrClass.dat'
        'Users\Administrator\AppData\Local\Microsoft\Windows\UsrClass.dat'
    )
    foreach ($rel in $usrTargets) {
        $dest = Join-Path $MountDir $rel
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $usrSrc -Destination $dest -Force
        Assert-PathExists -Path $dest -Label $rel
        Write-SubStep "installed UsrClass.dat -> $rel"
    }

    # 4. Pre-create the Administrator NTUSER.DAT from the Default hive so the
    #    runtime `reg load HKU\<AdminSID> X:\Users\Administrator\NTUSER.DAT`
    #    in the precreate step always has a hive to open. The donor install.wim
    #    has Users\Default\NTUSER.DAT but no Users\Administrator\NTUSER.DAT.
    $adminNtuser = Join-Path $MountDir 'Users\Administrator\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $adminNtuser)) {
        $defaultHive = Join-Path $MountDir 'Windows\System32\config\Default'
        Assert-PathExists -Path $defaultHive -Label 'Default hive'
        Copy-Item -LiteralPath $defaultHive -Destination $adminNtuser -Force
        Assert-PathExists -Path $adminNtuser -Label 'Users\Administrator\NTUSER.DAT'
        Write-SubStep 'pre-created Users\Administrator\NTUSER.DAT from config\Default'
    }
}
