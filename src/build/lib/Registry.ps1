#Requires -Version 7.0
<#
.SYNOPSIS
    Offline registry hive handling for an unmounted or mounted Windows image.

.DESCRIPTION
    The PE we build needs registry changes in four hives. The tutorials and every
    existing PE project use `reg load` / `reg import` for this; DISM's
    /Apply-Unattend is not usable because our .reg files are plain patches, not
    unattend components.

    Hives must be unloaded even when a patch fails, otherwise the mount directory
    cannot be dismounted and the build leaks a temp hive. Every entry point uses
    try/finally for that reason.
#>

$script:HiveMap = @(
    [pscustomobject]@{ File = 'DEFAULT';  Key = 'PE-DEF' }
    [pscustomobject]@{ File = 'DRIVERS';  Key = 'PE-DRV' }
    [pscustomobject]@{ File = 'SOFTWARE'; Key = 'PE-SOFT' }
    [pscustomobject]@{ File = 'SYSTEM';   Key = 'PE-SYS' }
)

function Get-PeHiveMap {
    [CmdletBinding()]
    param()

    return $script:HiveMap
}

function Test-RegistryHiveMounted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyName
    )

    $null = & reg.exe query "HKLM\$KeyName" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Mount-RegistryHive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $HiveFile,

        [Parameter(Mandatory = $true)]
        [string] $KeyName
    )

    Assert-PathExists -Path $HiveFile -Label 'Registry hive'

    if (Test-RegistryHiveMounted -KeyName $KeyName) {
        Write-Warn "hive HKLM\$KeyName already mounted, unloading first"
        Dismount-RegistryHive -KeyName $KeyName
    }

    Write-SubStep "loading $HiveFile -> HKLM\$KeyName"
    $null = & reg.exe load "HKLM\$KeyName" $HiveFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "reg load HKLM\$KeyName failed with exit code $LASTEXITCODE for $HiveFile")
    }
}

function Dismount-RegistryHive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyName
    )

    if (-not (Test-RegistryHiveMounted -KeyName $KeyName)) {
        return
    }

    Write-SubStep "unloading HKLM\$KeyName"
    $null = & reg.exe unload "HKLM\$KeyName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "reg unload HKLM\$KeyName failed with exit code $LASTEXITCODE")
    }
}

function Import-RegFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RegFile
    )

    Assert-PathExists -Path $RegFile -Label 'Registry patch'

    Write-SubStep "importing $(Split-Path -Leaf $RegFile)"
    $null = & reg.exe import $RegFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "reg import failed with exit code $LASTEXITCODE for $RegFile")
    }
}

function ConvertFrom-RegQueryOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Lines
    )

    # Pure parser for `reg query` output, kept separate so it is unit-testable
    # without a Windows host. Rows look like:
    #     1    REG_SZ    00000804
    # and the header line (the key path itself) is ignored.
    $values = @{}
    foreach ($line in $Lines) {
        # The name column is space-padded and may itself contain spaces
        # ("Layout Text"), so match up to the two-or-more spaces before REG_*.
        if ($line -match '^\s+(.+?)\s{2,}REG_[A-Z_]+\s+(.*\S)\s*$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
        elseif ($line -match '^\s+(.+?)\s{2,}REG_[A-Z_]+\s*$') {
            $values[$Matches[1]] = ''
        }
    }
    return $values
}

function Get-RegistryKeyValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $SubKey
    )

    # Reads a (possibly mounted) hive through reg.exe, never through the
    # PowerShell registry provider: the provider keeps an open handle on the
    # key, and a later `reg unload` then fails with exit code 1 (CI run
    # 44001157082 proved it). Returns $null when the key does not exist.
    $path = "HKLM\$KeyName"
    if ($SubKey) { $path = "$path\$SubKey" }

    # stderr is dropped: a missing key is signalled by the exit code, and
    # mixing ErrorRecords into $output would break the string[] binding.
    $output = & reg.exe query $path 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    # A query that prints nothing (or only blank lines) means "key exists,
    # no values": normalise to an empty array instead of letting a bare ""
    # hit the mandatory [string[]] binding of the parser (CI run 44001811418
    # proved reg.exe can return exactly one blank line here).
    $lines = @(@($output) | ForEach-Object { [string] $_ } | Where-Object { $_ -ne '' })
    return (ConvertFrom-RegQueryOutput -Lines $lines)
}

function Get-RegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $SubKey,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Name
    )

    $path = "HKLM:\$KeyName"
    if ($SubKey) { $path = "$path\$SubKey" }

    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if (-not $Name) { return $item }

    if ($item.PSObject.Properties.Name -contains $Name) {
        return $item.$Name
    }
    return $null
}

function Invoke-RegistryScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $RegFiles,

        [string[]] $Hives = @('DEFAULT', 'DRIVERS', 'SOFTWARE', 'SYSTEM')
    )

    $configDir = Join-Path $MountDir 'Windows/System32/config'
    Assert-PathExists -Path $configDir -Label 'config directory'

    $loaded = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($hive in $script:HiveMap) {
            if ($Hives -notcontains $hive.File) { continue }

            $file = Join-Path $configDir $hive.File
            if (-not (Test-Path -LiteralPath $file)) {
                Write-Warn "hive not present, skipping: $file"
                continue
            }

            Mount-RegistryHive -HiveFile $file -KeyName $hive.Key
            $loaded.Add($hive.Key)
        }

        foreach ($regFile in $RegFiles) {
            if (-not (Test-Path -LiteralPath $regFile)) {
                Write-Warn "registry patch not found, skipping: $regFile"
                continue
            }
            Import-RegFile -RegFile $regFile
        }
    }
    finally {
        for ($index = $loaded.Count - 1; $index -ge 0; $index--) {
            try {
                Dismount-RegistryHive -KeyName $loaded[$index]
            }
            catch {
                Write-Warn $_.Exception.Message
            }
        }
    }
}
