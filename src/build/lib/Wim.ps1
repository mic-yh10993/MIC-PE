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

function Clear-StagingReadOnly {
    <#
    .SYNOPSIS
        Clear the read-only attribute on a WIM-extracted staging tree.
    .DESCRIPTION
        wimlib-imagex extract restores the DOS attributes stored in the
        install.wim, and Windows system directories in the image carry
        the read-only attribute. A later step that writes into such a
        tree then fails with "Access to the path ... is denied": run
        45359151127 died on the shell step's StartAllBack.xml copy into
        the extracted icsxml directory, while the copy into the
        script-created MICPE directory succeeded. The registry step
        would hit the same wall (reg load/import and the SAM edit write
        the extracted hives in place, and unattend.xml lands in the
        extracted System32), so the attribute is cleared for the whole
        tree right after extraction, not just the one directory.

        The wildcard form matters: Microsoft's attrib docs say /S
        applies to "matching files", and the documented recursive
        spelling is `attrib -r b:\public\*.* /s`. A bare directory
        path with /S only matches the directory itself, so the previous
        spelling (`attrib -R <path> /S /D`) cleared the staging root
        but left the subdirectories read-only -- run 45368774235 ran
        it without error and the icsxml copy was still denied ~1.5s
        later. So this clears the root itself first, then everything
        under it with the wildcard form.

        Note the read-only attribute alone cannot be the whole story:
        a directory's read-only flag does not block creating files
        inside it, and the destination file here does not exist yet
        (it was never extracted -- the official image has no
        StartAllBack.xml). The likely real blocker is the ACL (see
        Grant-StagingWriteAccess); the attrib clearing stays as
        belt-and-braces.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $AttribPath = 'attrib.exe'
    )

    Assert-PathExists -Path $Path -Label 'staging tree'
    Write-SubStep "clearing read-only attributes on $Path"

    # $LASTEXITCODE is only set by native commands; the Pester fake is a
    # script, so it never sets the caller's value. Initialise it so the
    # check below also works in a fresh session (a real attrib overwrites
    # it with its own exit code).
    $LASTEXITCODE = 0
    & $AttribPath -R $Path /D 2>&1 | Out-Null
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "attrib -R failed with exit code $LASTEXITCODE for $Path"
    $LASTEXITCODE = 0
    & $AttribPath -R "$Path\*.*" /S /D 2>&1 | Out-Null
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "attrib -R failed with exit code $LASTEXITCODE for $Path\*.*"
}

function Grant-StagingWriteAccess {
    <#
    .SYNOPSIS
        Make sure the build account can write into a WIM-extracted path.
    .DESCRIPTION
        Folders and files arrive from the install.wim with an ACL that
        grants only TrustedInstaller, and a later write into such a
        path then fails with "Access to the path ... is denied" even
        after the read-only attribute is cleared: run 45368774235 ran
        Clear-StagingReadOnly without error and the shell step's
        StartAllBack.xml copy into the extracted icsxml directory was
        still denied ~1.5s later. A directory's read-only flag does
        not block creating files inside it, and the destination file
        does not exist yet, so the blocker is the ACL, not the
        attribute. This is the same failure Grant-FolderWriteAccess
        (UwpChain.ps1) handles for the UWP chain's AppRepository:
        take ownership for Administrators, then grant Administrators
        full control. takeown / icacls are used rather than a .NET
        FileSecurity object: changing the owner needs
        SeTakeOwnershipPrivilege, which the elevated build token
        already holds and the cmd tools enable by themselves. The ACE
        goes to BUILTIN\Administrators, never to "Everyone".

        Takes ownership recursively for a directory (takeown /R /D Y
        -- /D Y answers the prompt takeown shows for a directory it
        cannot list while recursing, so a non-interactive run never
        waits), of the file itself for a file, then grants
        Administrators full control -- recursive for a directory
        (icacls /T does not follow junctions). A missing path is a
        no-op, like Grant-FolderWriteAccess. The tools' output is
        written to the log and their exit codes are checked: a failed
        takeown throws here, and a non-zero icacls only warns -- its
        exit code is noisy on big trees, so the write probe
        (Show-StagingWriteState -AssertWritable, run by the base step
        on the CatRoot GUID directory) is the arbiter of whether the
        grant actually took. The post-grant attrib -R is likewise
        logged and throws on a non-zero exit (round 40: it clears the
        read-only flag on files a later copy will overwrite, and
        round 39 rerun proved a swallowed attrib is worth nothing --
        the grant printed cleanly while the first .cat copy was still
        denied).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $TakeownPath = 'takeown.exe',

        [string] $IcaclsPath = 'icacls.exe',

        [string] $AttribPath = 'attrib.exe'
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $isFile = -not (Test-Path -LiteralPath $Path -PathType Container)
    Write-SubStep "granting write access on $Path"
    # Round 39: takeown must be recursive for directories. The
    # non-recursive form only changed the owner of the directory
    # itself; the GUID subdirectories and .cat files underneath stayed
    # owned by TrustedInstaller, so the icacls /T grant below could not
    # add ACEs to them (it needs WRITE_DAC on each child) and failed
    # silently under /C. Round 38 died on exactly this: the CatRoot
    # grant printed cleanly and the first .cat copy was still denied.
    # /D Y answers the prompt takeown shows when it meets a directory
    # it cannot list while recursing, so the non-interactive CI run
    # never waits on it. Files have no children, so they keep the
    # non-recursive form.
    $takeownArgs = @('/F', $Path, '/A')
    if (-not $isFile) { $takeownArgs += @('/R', '/D', 'Y') }
    # $LASTEXITCODE is only set by native commands; initialise it so
    # the check below also works in a fresh session (same pattern as
    # Clear-StagingReadOnly). The output is logged, not discarded:
    # round 38 proved a clean-looking grant line is worth nothing
    # when the tools failed underneath it.
    $LASTEXITCODE = 0
    $takeownOut = & $TakeownPath @takeownArgs 2>&1
    $takeownCode = $LASTEXITCODE
    if ($takeownOut) { $takeownOut | Out-Host }
    Assert-True -Condition ($takeownCode -eq 0) -Message "takeown failed with exit code $takeownCode for $Path"
    # icacls exit codes are noisy on big trees (junctions, files it
    # cannot touch), so a non-zero code only warns here -- the write
    # probe after the grant is the arbiter of whether the grant took.
    $grantAce = if ($isFile) { '*S-1-5-32-544:F' } else { '*S-1-5-32-544:(OI)(CI)F' }
    $icaclsArgs = @($Path, '/Grant', $grantAce)
    if (-not $isFile) { $icaclsArgs += '/T' }
    $icaclsArgs += '/C'
    $LASTEXITCODE = 0
    $icaclsOut = & $IcaclsPath @icaclsArgs 2>&1
    $icaclsCode = $LASTEXITCODE
    if ($icaclsOut) { $icaclsOut | Out-Host }
    if ($icaclsCode -ne 0) {
        Write-Warn "icacls exited $icaclsCode for $Path (grant may be partial; the write probe after the grant is the arbiter)"
    }
    # Round 40: the post-grant attrib is no longer fire-and-forget.
    # The first .cat copy overwrites a file the serviced image already
    # ships (round 39 rerun), and this attrib -R is the step that
    # should have cleared that file's read-only flag -- but its output
    # was discarded and its exit code never checked, so there is no
    # record of whether it ran. Log the output and throw on a non-zero
    # exit, like takeown above. ($LASTEXITCODE is only set by native
    # commands; initialise it so the check also works in a fresh
    # session -- same pattern as Clear-StagingReadOnly. No test for the
    # failure path: on Linux pwsh $LASTEXITCODE is not set inside a
    # function, see the note at the end of this Describe block.)
    $LASTEXITCODE = 0
    if ($isFile) {
        $attribOut = & $AttribPath -R $Path 2>&1
    }
    else {
        $attribOut = & $AttribPath -R "$Path\*.*" /S /D 2>&1
    }
    $attribCode = $LASTEXITCODE
    if ($attribOut) { $attribOut | Out-Host }
    Assert-True -Condition ($attribCode -eq 0) -Message "attrib -R failed with exit code $attribCode for $Path"
}

function Show-StagingWriteState {
    <#
    .SYNOPSIS
        Print the attrib and icacls state of a path to the log.
    .DESCRIPTION
        Diagnostic: shows whether a path is writable before a step
        writes into it. Prints the attrib flags of the path (and, with
        -ShowContents, of the files directly inside it), the icacls
        ACL, and a write probe (create + delete a temp file). Used to
        tell a read-only-attribute blocker apart from an ACL/ownership
        blocker when a write into a WIM-extracted tree is denied: run
        45368774235 ran the attrib fix without error and the icsxml
        copy was still denied, so the log must show the real state
        instead of assuming the fix worked. The probe file is deleted
        immediately and never reaches the captured image. A missing
        path is reported, not an error. With -AssertWritable the
        function throws when the path is missing or the probe is
        denied (round 39: the base step probes the CatRoot GUID
        directory right after the grant, so a grant that did not take
        fails the build at the grant instead of at the .cat copy).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $Label = $Path,

        [switch] $ShowContents,

        [switch] $AssertWritable,

        [string] $AttribPath = 'attrib.exe',

        [string] $IcaclsPath = 'icacls.exe'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-SubStep "write state of $Label ($Path): path does not exist"
        if ($AssertWritable) {
            Assert-True -Condition $false -Message "write probe: $Label ($Path) does not exist, cannot write into it"
        }
        return
    }
    Write-SubStep "write state of $Label ($Path)"
    Write-Host "--- attrib $Path ---"
    & $AttribPath $Path 2>&1 | Out-Host
    if ($ShowContents) {
        & $AttribPath "$Path\*.*" 2>&1 | Out-Host
    }
    Write-Host "--- icacls $Path ---"
    & $IcaclsPath $Path 2>&1 | Out-Host
    $probe = Join-Path $Path 'micpe-write-probe.tmp'
    $probeOk = $false
    try {
        [System.IO.File]::WriteAllText($probe, 'probe')
        try { Remove-Item -LiteralPath $probe -Force -ErrorAction Stop } catch { }
        Write-Host '--- write probe: OK (created and deleted micpe-write-probe.tmp) ---'
        $probeOk = $true
    }
    catch {
        Write-Host "--- write probe: DENIED ($($_.Exception.Message)) ---"
    }
    if ($AssertWritable) {
        Assert-True -Condition $probeOk -Message "write probe denied for $Label ($Path): the grant did not take, see the icacls output above"
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

function Get-WimImageIndexByEdition {
    <#
    .SYNOPSIS
        Find the image index of a WIM whose Edition ID matches.
    .DESCRIPTION
        `wimlib-imagex info` prints one block per image, each starting with
        "Index:" and carrying an "Edition ID:" line. This finds the index
        whose edition matches (case-insensitive). If the WIM holds a single
        image, that index is returned regardless of the edition label:
        a single-edition UUP install.wim is that edition even when the
        label differs from the requested name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [Parameter(Mandatory = $true)]
        [string] $Edition,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    # $LASTEXITCODE is only set by native commands; the Pester fake is a
    # script, so it never sets the caller's value (see Get-WimBootIndex).
    $LASTEXITCODE = 0
    $info = & $WimlibPath info $WimPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "wimlib-imagex info failed with exit code $LASTEXITCODE for $WimPath")
    }
    $text = ($info -join "`n")

    # (?m)^ anchors "Index:" to a line start: the WIM header carries a
    # "Boot Index:" line (0 on a freshly generated install.wim), and the
    # unanchored pattern matched that substring, returning index 0 --
    # which wimlib rejects (error 18, indexes start at 1).
    $blocks = [regex]::Matches($text, '(?m)^Index:\s*(\d+)[\s\S]*?Edition ID:\s*([^\r\n]*)')
    $single = $null
    $found = @()
    foreach ($m in $blocks) {
        $idx = [int]$m.Groups[1].Value
        $ed = $m.Groups[2].Value.Trim()
        if ($null -eq $single) { $single = $idx }
        $found += $ed
        if ($ed -eq $Edition) { return $idx }
    }
    if ($blocks.Count -eq 1 -and $null -ne $single) {
        Write-Warn "install.wim has a single image (index $single); using it for edition '$Edition'"
        return $single
    }
    throw [System.InvalidOperationException]::new(
        ("install.wim has no image with Edition ID '{0}' (found: {1})" -f $Edition, ($found -join ', ')))
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

function New-WimCapture {
    <#
    .SYNOPSIS
        Capture a directory tree into a new bootable WIM (clean rebuild).
    .DESCRIPTION
        The clean rebuild assembles its PE as a plain directory tree
        (files extracted from the official install.wim plus the shell
        packages), then captures that tree into a fresh boot.wim. wimlib
        captures with LZX compression and an integrity table; --boot marks
        the new image as the boot image so winload starts it directly.
        The caller still calls Set-WimBootIndex -Index 1 afterwards: the
        capture creates a single-image WIM, and the boot-index field is
        re-asserted before packaging (same belt-and-braces as the m*
        iso step).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceDir,

        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [string] $Name = 'MICPE',

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $SourceDir -Label 'capture source directory'

    $parent = Split-Path -Parent $WimPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $WimPath) {
        Remove-Item -LiteralPath $WimPath -Force
    }

    Write-Step "capturing $SourceDir -> $WimPath"
    # $LASTEXITCODE is only set by native commands; the Pester fake is a
    # script, so it never sets the caller's value (see Get-WimBootIndex).
    $LASTEXITCODE = 0
    & $WimlibPath capture $SourceDir $WimPath $Name --compress=LZX --boot --check | Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "wimlib-imagex capture failed with exit code $LASTEXITCODE for $SourceDir"
    Assert-PathExists -Path $WimPath -Label 'captured boot.wim'
    return $WimPath
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
