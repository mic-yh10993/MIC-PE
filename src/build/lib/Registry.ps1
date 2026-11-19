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
    # Capture reg.exe's own output: swallowing it leaves a failed import
    # undiagnosable (CI run 44007177632 failed with exit code 1 and no
    # message at all). The Out-String keeps stderr ErrorRecords from
    # breaking the string binding.
    $output = & reg.exe import $RegFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $detail = if ($output) { $output.Trim() } else { '(reg.exe printed nothing)' }
        throw [System.InvalidOperationException]::new(
            "reg import failed with exit code $LASTEXITCODE for $RegFile : $detail")
    }
}

function Invoke-RegImportAsSystem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RegFile,

        [int] $TimeoutSeconds = 120
    )

    # Imports a .reg file as SYSTEM, through a one-shot scheduled task.
    #
    # Some keys in the 25H2 hives grant Administrators only KEY_READ: the
    # Appx sideload-policy key in SOFTWARE gives Administrators 0x00020019
    # and SYSTEM 0x000f003f (CI run 44040699722, regipy DACL read). A
    # build-time `reg import` of those values therefore fails with
    # "Error accessing the registry" for the admin running the build. The
    # DACL itself grants SYSTEM full control, so the import runs as SYSTEM
    # instead of weakening the hive DACL (never done: user decision
    # 2026-11-17 23:43 puts every registry import at CI build time and
    # forbids setting registry values inside the running PE).
    #
    # Mechanism: schtasks.exe is built into Windows, so no new tool is
    # downloaded. A wrapper .cmd (paths baked in, no argument quoting)
    # runs `reg import` and writes its exit code to a file; the caller
    # polls for that file, reads the code, and deletes the task. The
    # wrapper / code / log files live under ProgramData, where SYSTEM can
    # always write -- the runner user's temp dir is not guaranteed to be
    # writable by SYSTEM.
    Assert-PathExists -Path $RegFile -Label 'Registry patch'

    if ($null -eq (Get-Command -Name 'schtasks.exe' -ErrorAction SilentlyContinue)) {
        throw [System.InvalidOperationException]::new(
            'schtasks.exe is not available: a SYSTEM registry import needs Windows (one-shot scheduled task as SYSTEM)')
    }

    $taskName = "MICPE-RegImport-$([guid]::NewGuid().ToString('N'))"
    $workDir = Join-Path $env:ProgramData $taskName
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $wrapper = Join-Path $workDir 'import.cmd'
    $codeFile = Join-Path $workDir 'exitcode.txt'
    $logFile = Join-Path $workDir 'import.log'
    try {
        @(
            '@echo off',
            "reg.exe import `"$RegFile`" > `"$logFile`" 2>&1",
            "echo %ERRORLEVEL% > `"$codeFile`""
        ) | Set-Content -LiteralPath $wrapper -Encoding ascii

        # A /sc once task needs a start time; use two minutes in the
        # future (local time, same clock schtasks reads) and trigger it
        # immediately with /run -- the schedule itself never fires.
        $startAt = (Get-Date).AddMinutes(2).ToString('HH:mm')
        $create = & schtasks.exe /create /tn $taskName /tr "`"$wrapper`"" /sc once /st $startAt /ru SYSTEM /rl highest /f 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to create SYSTEM import task $taskName : $($create.Trim())")
        }

        $run = & schtasks.exe /run /tn $taskName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to start SYSTEM import task $taskName : $($run.Trim())")
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $codeFile)) {
            if ((Get-Date) -gt $deadline) {
                throw [System.InvalidOperationException]::new(
                    "SYSTEM registry import did not finish within $TimeoutSeconds seconds for $RegFile (task $taskName)")
            }
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Milliseconds 200
        $code = (Get-Content -LiteralPath $codeFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($null -eq $code) { $code = '' }
        $code = "$code".Trim()
        if ($code -ne '0') {
            $detail = '(reg.exe printed nothing)'
            if (Test-Path -LiteralPath $logFile) {
                $logged = (Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue)
                if ($logged) { $detail = "$logged".Trim() }
            }
            throw [System.InvalidOperationException]::new(
                "SYSTEM reg import failed with exit code $code for $RegFile : $detail")
        }
        Write-SubStep "imported $(Split-Path -Leaf $RegFile) as SYSTEM"
    }
    finally {
        $null = & schtasks.exe /delete /tn $taskName /f 2>&1
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RegImportPrivileged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RegFile,

        [Parameter(Mandatory = $true)]
        [string] $HiveKey,

        [int] $TimeoutSeconds = 120
    )

    # Writes a .reg patch into a mounted hive with backup/restore
    # privileges, through a one-shot scheduled task as SYSTEM.
    #
    # Run 51: the FeatureManagement group keys (Overrides\0, \15, \9)
    # give SYSTEM only KEY_READ (0x00020019), so even the SYSTEM import
    # above dies with "Error accessing the registry" on them (eval card
    # §37.4). SYSTEM does hold SeBackupPrivilege and SeRestorePrivilege,
    # so the import runs the privileged writer script
    # (Invoke-PrivilegedRegImport.ps1) instead of reg.exe: it enables
    # both privileges and creates the subkey with REG_OPTION_BACKUP_RESTORE
    # (which skips the key DACL and checks only the privilege), giving the
    # new subkey an explicit DACL (SYSTEM, Administrators and the Feature
    # Management service account, all full control) so the values can then
    # be written through an ordinary handle — run 52 proved RegSetValueEx
    # through a backup/restore handle returns success but the values
    # never land. No stock key's DACL is changed (the group keys and
    # every stock entry keep theirs); only the new subkey, which has no
    # stock DACL to preserve, carries the explicit one. The write still
    # happens at CI build time while the hive is mounted (user decision
    # 2026-11-17 23:43).
    Assert-PathExists -Path $RegFile -Label 'Registry patch'

    if ($null -eq (Get-Command -Name 'schtasks.exe' -ErrorAction SilentlyContinue)) {
        throw [System.InvalidOperationException]::new(
            'schtasks.exe is not available: a privileged registry import needs Windows (one-shot scheduled task as SYSTEM)')
    }

    $pwsh = (Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) {
        throw [System.InvalidOperationException]::new(
            'pwsh.exe is not available: the privileged registry import runs a PowerShell script as SYSTEM')
    }

    $script = Join-Path $PSScriptRoot 'Invoke-PrivilegedRegImport.ps1'
    Assert-PathExists -Path $script -Label 'Privileged registry import script'

    $taskName = "MICPE-PrivRegImport-$([guid]::NewGuid().ToString('N'))"
    $workDir = Join-Path $env:ProgramData $taskName
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $wrapper = Join-Path $workDir 'import.cmd'
    $codeFile = Join-Path $workDir 'exitcode.txt'
    $logFile = Join-Path $workDir 'import.log'
    try {
        @(
            '@echo off',
            "`"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$script`" -RegFile `"$RegFile`" -HiveKey `"$HiveKey`" > `"$logFile`" 2>&1",
            "echo %ERRORLEVEL% > `"$codeFile`""
        ) | Set-Content -LiteralPath $wrapper -Encoding ascii

        # A /sc once task needs a start time; use two minutes in the
        # future (local time, same clock schtasks reads) and trigger it
        # immediately with /run -- the schedule itself never fires.
        $startAt = (Get-Date).AddMinutes(2).ToString('HH:mm')
        $create = & schtasks.exe /create /tn $taskName /tr "`"$wrapper`"" /sc once /st $startAt /ru SYSTEM /rl highest /f 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to create privileged import task $taskName : $($create.Trim())")
        }

        $run = & schtasks.exe /run /tn $taskName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to start privileged import task $taskName : $($run.Trim())")
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $codeFile)) {
            if ((Get-Date) -gt $deadline) {
                throw [System.InvalidOperationException]::new(
                    "privileged registry import did not finish within $TimeoutSeconds seconds for $RegFile (task $taskName)")
            }
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Milliseconds 200
        $code = (Get-Content -LiteralPath $codeFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($null -eq $code) { $code = '' }
        $code = "$code".Trim()
        if ($code -ne '0') {
            $detail = '(the privileged import printed nothing)'
            if (Test-Path -LiteralPath $logFile) {
                $logged = (Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue)
                if ($logged) { $detail = "$logged".Trim() }
            }
            throw [System.InvalidOperationException]::new(
                "privileged reg import failed with exit code $code for $RegFile : $detail")
        }
        # The privileged writer prints one line per value it writes;
        # surface them in the build log so a later read-back can say
        # exactly what landed (and where), not just that the task
        # exited 0.
        if (Test-Path -LiteralPath $logFile) {
            $logged = (Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
            foreach ($line in $logged) {
                if ("$line".Trim()) { Write-Host "  [priv-import] $line" }
            }
        }
        Write-SubStep "imported $(Split-Path -Leaf $RegFile) as SYSTEM (backup/restore)"
    }
    finally {
        $null = & schtasks.exe /delete /tn $taskName /f 2>&1
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
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

        [string[]] $Hives = @('DEFAULT', 'DRIVERS', 'SOFTWARE', 'SYSTEM'),

        # Leaf names of .reg files whose keys the build admin cannot write
        # (Appx sideload policy: Administrators have only KEY_READ, CI run
        # 44040699722). Those files are imported as SYSTEM through a
        # one-shot scheduled task (Invoke-RegImportAsSystem) instead of a
        # plain reg import; everything else keeps the admin path.
        [string[]] $SystemRegFiles = @(),

        # Leaf names of .reg files whose keys even SYSTEM cannot write
        # (FeatureManagement group keys give SYSTEM only KEY_READ, run 51).
        # Those files are written with backup/restore privileges
        # (Invoke-RegImportPrivileged) instead of a reg import; a file
        # belongs in exactly one of SystemRegFiles and PrivilegedRegFiles.
        [string[]] $PrivilegedRegFiles = @()
    )

    $configDir = Join-Path $MountDir 'Windows/System32/config'
    Assert-PathExists -Path $configDir -Label 'config directory'

    $systemHiveKey = ($script:HiveMap | Where-Object { $_.File -eq 'SYSTEM' }).Key

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
            if ($PrivilegedRegFiles -contains (Split-Path -Leaf $regFile)) {
                Invoke-RegImportPrivileged -RegFile $regFile -HiveKey $systemHiveKey
            }
            elseif ($SystemRegFiles -contains (Split-Path -Leaf $regFile)) {
                Invoke-RegImportAsSystem -RegFile $regFile
            }
            else {
                Import-RegFile -RegFile $regFile
            }
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
