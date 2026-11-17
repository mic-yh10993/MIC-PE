#Requires -Version 7.0
<#
.SYNOPSIS
    Installer deploy step for the MICPE installer (M6, Task 16).

.DESCRIPTION
    Index selection, target space/safety checks, DISM apply and boot
    repair. The pure functions (Select-DefaultIndex, Test-TargetSpace on
    byte counts, Test-TargetSafety, ConvertFrom-WimInfoOutput) run anywhere;
    the functions that touch disks (Invoke-Deploy, Repair-Boot) require
    Windows and take a -CommandRunner seam so tests can capture the command
    sequence without formatting a real disk.

    M7 decision: the apply/info tool is DISM, not wimlib-imagex.
    dism.exe ships inside every WinPE (verified in the shipped boot.wim,
    both indexes), while wimlib-imagex.exe only exists on the build host.
    Shipping wimlib into the PE would have meant a new payload binary plus
    its libwim-15.dll and re-pinning the prepared payload-v1 archive; DISM
    costs nothing and is Microsoft's documented tool for applying images in
    WinPE. The build host still uses wimlib-imagex for extraction
    (src/build/lib/Wim.ps1) -- only the in-PE runtime path changed.

    # reuse-check: the 1.15 headroom rule, the two parameter sets of
    Test-TargetSpace and the Review Focus mapping come from docs/plan.md
    Task 16; the -CommandRunner seam copies the pattern from
    src/build/lib/Payload.ps1 (Invoke-ComponentInstall).
#>

function ConvertFrom-WimInfoOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines = @()
    )

    # Parses `dism.exe /English /Get-WimInfo` output (M7: the in-PE tool
    # is DISM, not wimlib-imagex). Verified format (Microsoft Learn):
    #   Deployment Image Servicing and Management tool
    #   Version: 10.0.14393.0
    #   Details for image : F:\sources\install.esd
    #   Index : 1
    #   Name : Windows 10 Pro
    #   Description : Windows 10 Pro
    #   Size : 14,747,431,455 bytes
    # /English pins the field names; without it a localized DISM prints
    # the same lines in the system language and this parser finds nothing.
    $indexes = [System.Collections.Generic.List[pscustomobject]]::new()
    $current = $null

    foreach ($line in $Lines) {
        if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') {
            $current = [pscustomobject]@{
                Index       = [int] $Matches[1]
                Name        = ''
                Description = ''
                SizeBytes   = 0
            }
            $indexes.Add($current)
        }
        elseif ($null -ne $current -and $line -match '^\s*Name\s*:\s*(.*?)\s*$') {
            $current.Name = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^\s*Description\s*:\s*(.*?)\s*$') {
            $current.Description = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^\s*Size\s*:\s*([\d,]+)\s+bytes\s*$') {
            $current.SizeBytes = [long] ($Matches[1] -replace ',', '')
        }
    }

    return ,$indexes.ToArray()
}

function Get-WimIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        # dism.exe is in System32 in every WinPE, so the default resolves
        # without shipping anything. The WimlibPath alias keeps older
        # callers (and the M6 tests) working unchanged.
        [Alias('WimlibPath')]
        [string] $DismPath = 'dism.exe'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    $output = & $DismPath /English /Get-WimInfo /WimFile:$WimPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "dism.exe /Get-WimInfo failed with exit code $LASTEXITCODE for $WimPath")
    }

    $indexes = ConvertFrom-WimInfoOutput -Lines ($output -split "`r?`n")
    if ($indexes.Count -eq 0) {
        throw [System.InvalidOperationException]::new("no indexes found in $WimPath")
    }
    return ,$indexes
}

function Select-DefaultIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Indexes = @(),

        [string] $DisplayName = ''
    )

    if ($Indexes.Count -eq 0) {
        throw [System.InvalidOperationException]::new('no image indexes to select from')
    }

    if ($DisplayName) {
        # Exact name match first, then a name containing the display name
        # (Review Focus #3: default to the index matching install.mic).
        $exact = @($Indexes | Where-Object { $_.Name -eq $DisplayName })
        if ($exact.Count -gt 0) {
            return [int] $exact[0].Index
        }
        $partial = @($Indexes | Where-Object { $_.Name -like "*${DisplayName}*" })
        if ($partial.Count -gt 0) {
            return [int] $partial[0].Index
        }
    }

    return [int] $Indexes[0].Index
}

function Test-TargetSpace {
    [CmdletBinding(DefaultParameterSetName = 'Bytes')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Bytes')]
        [long] $RequiredBytes,

        [Parameter(Mandatory = $true, ParameterSetName = 'Bytes')]
        [long] $AvailableBytes,

        [Parameter(Mandatory = $true, ParameterSetName = 'Wim')]
        [string] $WimPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Wim')]
        [int] $Index,

        [Parameter(Mandatory = $true, ParameterSetName = 'Wim')]
        [string] $TargetRoot,

        [Parameter(ParameterSetName = 'Wim')]
        [Alias('WimlibPath')]
        [string] $DismPath = 'dism.exe'
    )

    if ($PSCmdlet.ParameterSetName -eq 'Wim') {
        $indexes = Get-WimIndexes -WimPath $WimPath -DismPath $DismPath
        $entry = @($indexes | Where-Object { $_.Index -eq $Index })
        if ($entry.Count -eq 0) {
            throw [System.InvalidOperationException]::new(
                "index $Index not found in $WimPath")
        }
        $RequiredBytes = $entry[0].SizeBytes

        if (-not $IsWindows) {
            throw [System.InvalidOperationException]::new(
                'Test-TargetSpace -WimPath requires Windows (drive free space)')
        }
        $letter = $TargetRoot.Substring(0, 1)
        $drive = Get-PSDrive -Name $letter -ErrorAction Stop
        $AvailableBytes = $drive.Free
    }

    # DISM reports the uncompressed size; 1.15 leaves headroom. Ceiling
    # (not truncation): 1000 * 1.15 must come out as 1150, not 1149.
    $required = [long] [Math]::Ceiling([double] $RequiredBytes * 1.15)
    return [pscustomobject]@{
        Required  = $required
        Available = $AvailableBytes
        Ok        = ($AvailableBytes -ge $required)
    }
}

function Test-TargetSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $TargetRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $ImageRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $PeRoot
    )

    $target = $TargetRoot.Trim().TrimEnd('\', '/').ToUpperInvariant()
    $image = $ImageRoot.Trim().TrimEnd('\', '/').ToUpperInvariant()
    $pe = $PeRoot.Trim().TrimEnd('\', '/').ToUpperInvariant()

    if (-not $target -or $target -notmatch '^[A-Z]:$') {
        return [pscustomobject]@{ Ok = $false; Reason = '目标不是有效的卷根（例如 C:\）' }
    }
    if ($target -eq $image) {
        # Review Focus #4: never install onto the volume holding the image.
        return [pscustomobject]@{ Ok = $false; Reason = '目标卷就是镜像所在的卷，不能往装机源自己身上装系统' }
    }
    if ($target -eq $pe) {
        return [pscustomobject]@{ Ok = $false; Reason = '目标卷是正在运行的 PE 所在卷，不能覆盖正在运行的系统' }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Invoke-DeployCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Exe,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Arguments = @(),

        [scriptblock] $CommandRunner = $null
    )

    if ($null -ne $CommandRunner) {
        return [int] (& $CommandRunner $Exe $Arguments)
    }

    & $Exe @Arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-Deploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [Parameter(Mandatory = $true)]
        [int] $Index,

        [Parameter(Mandatory = $true)]
        [string] $TargetRoot,

        [Alias('WimlibPath')]
        [string] $DismPath = 'dism.exe',

        [scriptblock] $CommandRunner = $null
    )

    if ($null -eq $CommandRunner -and -not $IsWindows) {
        throw [System.InvalidOperationException]::new(
            'Invoke-Deploy requires Windows (format.com / dism.exe)')
    }
    Assert-PathExists -Path $WimPath -Label 'WIM'

    $letter = $TargetRoot.Substring(0, 1)

    # Unmount the target volume first so format.com does not trip over an
    # open handle; best effort — format itself is the hard gate.
    $null = Invoke-DeployCommand -Exe 'mountvol.exe' -Arguments @("${letter}:", '/D') `
        -CommandRunner $CommandRunner

    $formatCode = Invoke-DeployCommand -Exe 'format.com' `
        -Arguments @("${letter}:", '/FS:NTFS', '/Q', '/Y') -CommandRunner $CommandRunner
    if ($formatCode -ne 0) {
        throw [System.InvalidOperationException]::new(
            "format.com failed with exit code $formatCode for ${letter}:")
    }

    # DISM /Apply-Image (M7: replaces `wimlib-imagex apply`). No
    # /ScratchDir: Microsoft's own WinPE examples run the plain form, and
    # the apply streams files rather than staging them; if an L3 run ever
    # reports a scratch-space error, point /ScratchDir at the target drive.
    # No /SWMFile branch: the discoverer only ever returns .wim/.esd, and
    # the wizard's file picker only accepts *.wim|*.esd.
    $applyCode = Invoke-DeployCommand -Exe $DismPath `
        -Arguments @('/English', '/Apply-Image', "/ImageFile:$WimPath", "/Index:$Index", "/ApplyDir:$TargetRoot") -CommandRunner $CommandRunner
    return $applyCode
}

function Repair-Boot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $TargetRoot,

        [string] $BootRoot = '',

        [scriptblock] $CommandRunner = $null
    )

    if ($null -eq $CommandRunner -and -not $IsWindows) {
        throw [System.InvalidOperationException]::new(
            'Repair-Boot requires Windows (bcdboot)')
    }

    $boot = if ($BootRoot) { $BootRoot } else { $TargetRoot }
    # String concatenation, not Join-Path: on a Linux host Join-Path treats
    # 'C:' as a PSDrive name and throws; the target is a Windows path.
    $windowsDir = $TargetRoot.TrimEnd('\') + '\Windows'
    return [int] (Invoke-DeployCommand -Exe 'bcdboot.exe' `
        -Arguments @($windowsDir, '/s', $boot, '/f', 'ALL') -CommandRunner $CommandRunner)
}
