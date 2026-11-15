#Requires -Version 7.0
<#
.SYNOPSIS
    ISO packaging for MICPE: dual-boot (BIOS + UEFI) via oscdimg, size assertion.

.DESCRIPTION
    oscdimg is the only ADK component this project needs. The boot files come from
    the Windows media directory itself (etfsboot.com for BIOS, efisys.bin for
    UEFI), so no ADK installation is required beyond having oscdimg on PATH or
    pointed at explicitly.
#>

$script:IsoMaxBytes = 3.5GB

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
    $efi = Join-Path $MediaDir 'efi/microsoft/boot/efisys.bin'
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
