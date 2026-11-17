#Requires -Version 7.0
<#
.SYNOPSIS
    Installer deploy step for the MICPE installer (M6, Task 16).

.DESCRIPTION
    Index selection, target space/safety checks, wimlib apply and boot
    repair. The pure functions (Select-DefaultIndex, Test-TargetSpace on
    byte counts, Test-TargetSafety, ConvertFrom-WimInfoOutput) run anywhere;
    the functions that touch disks (Invoke-Deploy, Repair-Boot) require
    Windows and take a -CommandRunner seam so tests can capture the command
    sequence without formatting a real disk.

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

    $indexes = [System.Collections.Generic.List[pscustomobject]]::new()
    $current = $null

    foreach ($line in $Lines) {
        if ($line -match '^\s*Index:\s*(\d+)\s*$') {
            $current = [pscustomobject]@{
                Index       = [int] $Matches[1]
                Name        = ''
                Description = ''
                SizeBytes   = 0
            }
            $indexes.Add($current)
        }
        elseif ($null -ne $current -and $line -match '^\s*Name:\s*(.*?)\s*$') {
            $current.Name = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^\s*Description:\s*(.*?)\s*$') {
            $current.Description = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^\s*Total Bytes:\s*(\d+)\s*$') {
            $current.SizeBytes = [long] $Matches[1]
        }
    }

    return ,$indexes.ToArray()
}

function Get-WimIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WimPath,

        [string] $WimlibPath = 'wimlib-imagex'
    )

    Assert-PathExists -Path $WimPath -Label 'WIM'

    $output = & $WimlibPath info $WimPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "wimlib-imagex info failed with exit code $LASTEXITCODE for $WimPath")
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
        [string] $WimlibPath = 'wimlib-imagex'
    )

    if ($PSCmdlet.ParameterSetName -eq 'Wim') {
        $indexes = Get-WimIndexes -WimPath $WimPath -WimlibPath $WimlibPath
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

    # wimlib reports the uncompressed size; 1.15 leaves headroom. Ceiling
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

        [string] $WimlibPath = 'wimlib-imagex',

        [scriptblock] $CommandRunner = $null
    )

    if ($null -eq $CommandRunner -and -not $IsWindows) {
        throw [System.InvalidOperationException]::new(
            'Invoke-Deploy requires Windows (format.com / wimlib-imagex)')
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

    $applyCode = Invoke-DeployCommand -Exe $WimlibPath `
        -Arguments @('apply', $WimPath, "$Index", $TargetRoot) -CommandRunner $CommandRunner
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
