#Requires -Version 7.0
<#
.SYNOPSIS
    ISO packaging for MICPE: dual-boot (BIOS + UEFI) via oscdimg, size assertion.

.DESCRIPTION
    oscdimg is the only ADK component this project needs. The boot files come from
    the Windows media directory itself (etfsboot.com for BIOS, the no-prompt
    El Torito image efisys_noprompt.bin for UEFI), so no ADK installation is
    required beyond having oscdimg on PATH or pointed at explicitly.

    UEFI uses efisys_noprompt.bin, NOT the prompting efisys.bin. The prompting
    image's cdboot.efi shows "Press any key to boot from CD or DVD" and times
    out after about 3 seconds; the harness's boot keys arrive at +15 s at the
    earliest, so the prompt always expired first and the firmware reported
    "BdsDxe: failed to start Boot0001 ... : Time out" (run 44046530462).
    The no-prompt image boots straight into bootmgfw.efi with no key race.
    Local TCG repro 2026-11-17: no keys -> same BdsDxe timeout at +8 s;
    keys at +6/+7/+8 s (inside the prompt window) -> boot proceeded past
    cdboot with no BDS error. See eval card section 11.
#>

# The product target is a <= 3.2 GB ISO (plan.md), but a full 26200 media is
# ~4.5 GiB (install.wim alone is ~4.1 GiB), so no full-media build can pass
# a 3.2 GB gate. Shrinking the media (trimming or splitting install.wim)
# is M7 volume governance, not an M1 gate: this cap only guards against
# runaway growth, and M7 must lower it again once the media actually fits.
$script:IsoMaxBytes = 5GB

function Get-OscdimgPath {
    [CmdletBinding()]
    param(
        [string] $AdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
    )

    # oscdimg ships in the ADK, but the ADK installer does not put its
    # Deployment Tools directory on PATH, so a bare 'oscdimg' only resolves
    # when someone added it by hand. Check PATH first, then the well-known
    # ADK locations (amd64, then x86).
    $onPath = Get-Command oscdimg -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    foreach ($arch in 'amd64', 'x86') {
        $candidate = Join-Path $AdkRoot "Assessment and Deployment Kit\Deployment Tools\$arch\Oscdimg\oscdimg.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    throw [System.InvalidOperationException]::new(
        'oscdimg not found: install the Windows ADK Deployment Tools or put oscdimg on PATH')
}

function Get-OscdimgArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaDir,

        [Parameter(Mandatory = $true)]
        [string] $OutIso,

        [Parameter(Mandatory = $true)]
        [string] $BiosBootFile,

        [Parameter(Mandatory = $true)]
        [string] $EfiBootFile,

        [string] $Label = 'MICPE'
    )

    return @(
        '-m'
        '-o'
        '-u2'
        '-udfver102'
        "-l$Label"
        "-bootdata:2#p0,e,b$BiosBootFile#pEF,e,b$EfiBootFile"
        $MediaDir
        $OutIso
    )
}

function New-MicpeIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MediaDir,

        [Parameter(Mandatory = $true)]
        [string] $OutIso,

        [string] $OscdimgPath = 'oscdimg',

        [string] $Label = 'MICPE'
    )

    Assert-PathExists -Path $MediaDir -Label 'Media directory'

    $bios = Join-Path $MediaDir 'boot/etfsboot.com'
    # No-prompt El Torito image: the prompting efisys.bin times out after
    # ~3 s and no harness key can land in that window (run 44046530462).
    $efi = Join-Path $MediaDir 'efi/microsoft/boot/efisys_noprompt.bin'
    Assert-PathExists -Path $bios -Label 'BIOS boot sector'
    Assert-PathExists -Path $efi -Label 'UEFI boot image'

    $outDir = Split-Path -Parent $OutIso
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $args = Get-OscdimgArgs -MediaDir $MediaDir -OutIso $OutIso `
        -BiosBootFile $bios -EfiBootFile $efi -Label $Label

    Write-Step 'building ISO'
    & $OscdimgPath @args | Out-Host
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Message "oscdimg failed with exit code $LASTEXITCODE"

    Assert-PathExists -Path $OutIso -Label 'ISO'
    Assert-FileSize -Path $OutIso -MaxBytes $script:IsoMaxBytes -Label 'MICPE.iso'
}
