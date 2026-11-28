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
        # Run 55: reg.exe exited 0 while the values never landed, and
        # the import log was deleted with the workdir — the miss was
        # silent until the build-time assert caught it. Surface the
        # log and read the values back here, at the import step, so a
        # future miss fails here with the evidence attached instead of
        # three steps later.
        if (Test-Path -LiteralPath $logFile) {
            $logged = (Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
            foreach ($line in $logged) {
                if ("$line".Trim()) { Write-Host "  [sys-import] $line" }
            }
        }
        Assert-RegImportLanded -RegFile $RegFile
        Write-SubStep "imported $(Split-Path -Leaf $RegFile) as SYSTEM"
    }
    finally {
        $null = & schtasks.exe /delete /tn $taskName /f 2>&1
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-CleanRegOutputHasError {
    # Does a reg.exe query output carry a reg.exe error line?
    # reg.exe can print an error AND exit 0 (round 42 rerun 15:
    # run 46146459319 printed "ERROR: Access is denied." for a
    # /s query of the staged SAM and still exited 0), so
    # $LASTEXITCODE alone cannot tell a failed query from an
    # empty database. Only a line that starts with "ERROR:"
    # counts -- a value that merely mentions ERROR: mid-line
    # does not.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RegOutput
    )

    return @($RegOutput -split "`r?`n" | Where-Object { $_ -match '^\s*ERROR:' }).Count -gt 0
}

function Get-CleanSystemRegQueryScript {
    # The task script Invoke-CleanSystemRegQuery runs as SYSTEM:
    # load the hive, run one reg.exe query, unload, and write the
    # exit codes plus the FULL load and query outputs to files.
    # Pure (no Windows calls), so it is unit-testable on Linux.
    # The paths are baked into single quotes (they never contain
    # one); the recurse flag is baked in as '/s' or nothing, so
    # the generated text never contains a stray /s.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $HiveFile,

        [Parameter(Mandatory = $true)]
        [string] $HiveKey,

        [Parameter(Mandatory = $true)]
        [string] $QuerySubKey,

        [Parameter(Mandatory = $true)]
        [string] $LoadOutputFile,

        [Parameter(Mandatory = $true)]
        [string] $QueryOutputFile,

        [Parameter(Mandatory = $true)]
        [string] $CodesFile,

        [switch] $Recurse
    )

    $recurseFlag = if ($Recurse) { '/s' } else { '' }
    $body = @'
# 'Continue', not 'Stop': this script's only job is to record reg.exe's
# exit codes. Under 'Stop', a reg.exe line on stderr (2>&1) is a
# terminating error in Windows PowerShell 5.1, so a failed load would
# kill the script before codes.txt is written and the caller could not
# tell a load failure from a broken task (run 46153205670).
$ErrorActionPreference = 'Continue'
$loadRaw = & reg.exe load 'HKLM\__HIVEKEY__' '__HIVEFILE__' 2>&1
$loadCode = $LASTEXITCODE
($loadRaw | Out-String) | Set-Content -LiteralPath '__LOADOUT__' -Encoding utf8
$queryOut = ''
$queryCode = -1
if ($loadCode -eq 0) {
    $queryRaw = & reg.exe query 'HKLM\__HIVEKEY__\__QUERYSUBKEY__' __RECURSE__ 2>&1
    $queryCode = $LASTEXITCODE
    $queryOut = ($queryRaw | Out-String)
}
($queryOut | Out-String) | Set-Content -LiteralPath '__QUERYOUT__' -Encoding utf8
$unloadCode = -1
if ($loadCode -eq 0) {
    $null = & reg.exe unload 'HKLM\__HIVEKEY__' 2>&1
    $unloadCode = $LASTEXITCODE
}
# Interpolation, not '...' + $code: @('loadExit=' + $loadCode, ...) parses
# as 'loadExit=' + ($loadCode, 'queryExit=' + ...) and collapses to ONE
# space-joined string, so codes.txt was a single line and the caller
# parsed every exit code as -1 even though the load succeeded
# (run 46153205670). Interpolation keeps one code per line.
@("loadExit=$loadCode", "queryExit=$queryCode", "unloadExit=$unloadCode") | Set-Content -LiteralPath '__CODES__' -Encoding utf8
'@
    $body = $body.Replace('__HIVEKEY__', $HiveKey).Replace('__HIVEFILE__', $HiveFile).Replace('__QUERYSUBKEY__', $QuerySubKey).Replace('__RECURSE__', $recurseFlag).Replace('__LOADOUT__', $LoadOutputFile).Replace('__QUERYOUT__', $QueryOutputFile).Replace('__CODES__', $CodesFile)
    return $body
}

function Get-CleanSystemRegQueryCodes {
    # Parse the exit-code file a SYSTEM task script wrote
    # (Get-CleanSystemRegQueryScript) and return the three codes.
    #
    # The file is normally one code per line, but the parse tolerates
    # a collapsed single line ("loadExit=0 queryExit=0 unloadExit=0"):
    # round 42 rerun 15 wrote exactly that shape (the codes array
    # collapsed, run 46153205670) and the old anchored line regex
    # parsed every code as -1 even though the load had succeeded.
    # A code that never parsed stays -1, the "unknown" sentinel the
    # caller already treats as a failure; a BOM prefix is stripped
    # defensively (Set-Content -Encoding utf8 writes one under
    # Windows PowerShell 5.1).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CodesFile
    )

    $codes = [pscustomobject]@{
        LoadExitCode   = -1
        QueryExitCode  = -1
        UnloadExitCode = -1
    }
    $raw = (Get-Content -LiteralPath $CodesFile -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $raw) { $raw = '' }
    foreach ($token in (@($raw -split '\s+' | Where-Object { $_ }))) {
        $token = $token.Trim([char]0xFEFF)
        if ($token -match '^loadExit=(-?\d+)$') { $codes.LoadExitCode = [int]$Matches[1] }
        elseif ($token -match '^queryExit=(-?\d+)$') { $codes.QueryExitCode = [int]$Matches[1] }
        elseif ($token -match '^unloadExit=(-?\d+)$') { $codes.UnloadExitCode = [int]$Matches[1] }
    }
    return $codes
}

function Invoke-CleanSystemRegQuery {
    # Run one reg.exe query against an offline hive as SYSTEM
    # and return the full output.
    #
    # Round 42 rerun 15 root cause (run 46146459319, and the
    # seed-side run 46134591088 before it): the harvested SAM's
    # keys carry the live-system DACL -- SYSTEM has KEY_ALL_ACCESS
    # (0xF003F) but Administrators only READ_CONTROL|WRITE_DAC
    # (0x60000, no KEY_QUERY_VALUE / KEY_ENUMERATE_SUB_KEYS), so
    # an admin reg.exe query on Users\Names fails with "ERROR:
    # Access is denied." while reg.exe still exits 0. The query
    # therefore runs as SYSTEM through the same one-shot
    # scheduled-task mechanism Set-OfflineAdminState uses for SAM
    # surgery (and Invoke-RegImportAsSystem for DACL-blocked
    # imports): load, query and unload all happen inside the
    # SYSTEM task, so the admin shell never touches the keys.
    # The hive file itself is only read, never modified, and no
    # key DACL is weakened.
    #
    # Returns a pscustomobject with LoadExitCode, QueryExitCode,
    # UnloadExitCode, LoadOutput (the full load output text) and
    # QueryOutput (the full listing text). A load or query failure
    # is RETURNED, not thrown, so the caller can say which step
    # failed; only the task infrastructure itself (schtasks,
    # timeout, missing output files) throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $HiveFile,

        [Parameter(Mandatory = $true)]
        [string] $HiveKey,

        [Parameter(Mandatory = $true)]
        [string] $QuerySubKey,

        [switch] $Recurse,

        [int] $TimeoutSeconds = 120
    )

    if ($null -eq (Get-Command -Name 'schtasks.exe' -ErrorAction SilentlyContinue)) {
        throw [System.InvalidOperationException]::new(
            'schtasks.exe is not available: a SYSTEM registry query needs Windows (one-shot scheduled task as SYSTEM)')
    }

    $taskName = "MICPE-SysRegQuery-$([guid]::NewGuid().ToString('N'))"
    $workDir = Join-Path $env:ProgramData $taskName
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $loader = Join-Path $workDir 'query-hive.ps1'
    $codeFile = Join-Path $workDir 'exitcode.txt'
    $loadOutFile = Join-Path $workDir 'load.log'
    $queryOutFile = Join-Path $workDir 'query.log'
    $codesFile = Join-Path $workDir 'codes.txt'
    $scriptPath = Join-Path $workDir 'run-query.cmd'
    try {
        Set-Content -LiteralPath $loader -Value (Get-CleanSystemRegQueryScript -HiveFile $HiveFile -HiveKey $HiveKey -QuerySubKey $QuerySubKey -LoadOutputFile $loadOutFile -QueryOutputFile $queryOutFile -CodesFile $codesFile -Recurse:$Recurse) -Encoding utf8
        @(
            '@echo off',
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$loader`" > `"$queryOutFile.console`" 2>&1",
            "echo %ERRORLEVEL% > `"$codeFile`""
        ) | Set-Content -LiteralPath $scriptPath -Encoding ascii

        # A /sc once task needs a start time; use two minutes in the
        # future (local time, same clock schtasks reads) and trigger it
        # immediately with /run -- the schedule itself never fires.
        $startAt = (Get-Date).AddMinutes(2).ToString('HH:mm')
        $create = & schtasks.exe /create /tn $taskName /tr "`"$scriptPath`"" /sc once /st $startAt /ru SYSTEM /rl highest /f 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to create SYSTEM registry query task $taskName : $($create.Trim())")
        }
        Write-SubStep "created SYSTEM registry query task $taskName"

        $run = & schtasks.exe /run /tn $taskName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to start SYSTEM registry query task $taskName : $($run.Trim())")
        }
        Write-SubStep "started SYSTEM registry query task $taskName for $QuerySubKey"

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $codeFile)) {
            if ((Get-Date) -gt $deadline) {
                throw [System.InvalidOperationException]::new(
                    "SYSTEM registry query did not finish within $TimeoutSeconds seconds for $QuerySubKey (task $taskName)")
            }
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Milliseconds 200
        $code = (Get-Content -LiteralPath $codeFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($null -eq $code) { $code = '' }
        $code = "$code".Trim()
        if ($code -ne '0') {
            $detail = '(the SYSTEM query script printed nothing)'
            if (Test-Path -LiteralPath "$queryOutFile.console") {
                $logged = (Get-Content -LiteralPath "$queryOutFile.console" -Raw -ErrorAction SilentlyContinue)
                if ($logged) { $detail = "$logged".Trim() }
            }
            throw [System.InvalidOperationException]::new(
                "SYSTEM registry query task failed with exit code $code for $QuerySubKey : $detail")
        }
        Write-SubStep "SYSTEM registry query task finished (task script exit code 0) for $QuerySubKey"

        if (-not (Test-Path -LiteralPath $codesFile)) {
            throw [System.InvalidOperationException]::new(
                "SYSTEM registry query task finished but wrote no exit codes for $QuerySubKey (task $taskName)")
        }
        $codes = Get-CleanSystemRegQueryCodes -CodesFile $codesFile
        $loadExit = $codes.LoadExitCode
        $queryExit = $codes.QueryExitCode
        $unloadExit = $codes.UnloadExitCode
        if (($loadExit -eq -1) -and ($queryExit -eq -1) -and ($unloadExit -eq -1)) {
            $codesText = (Get-Content -LiteralPath $codesFile -Raw -ErrorAction SilentlyContinue)
            if ($null -eq $codesText) { $codesText = '' }
            throw [System.InvalidOperationException]::new(
                "SYSTEM registry query task wrote an unparseable exit-code file for $QuerySubKey (task $taskName): [$($codesText.Trim())]")
        }
        Write-SubStep ("SYSTEM registry query codes: loadExit={0} queryExit={1} unloadExit={2}" -f $loadExit, $queryExit, $unloadExit)
        $loadOutput = ''
        if (Test-Path -LiteralPath $loadOutFile) {
            $loadOutput = (Get-Content -LiteralPath $loadOutFile -Raw -ErrorAction SilentlyContinue)
            if ($null -eq $loadOutput) { $loadOutput = '' }
        }
        $queryOutput = ''
        if (Test-Path -LiteralPath $queryOutFile) {
            $queryOutput = (Get-Content -LiteralPath $queryOutFile -Raw -ErrorAction SilentlyContinue)
            if ($null -eq $queryOutput) { $queryOutput = '' }
        }
        return [pscustomobject]@{
            LoadExitCode   = $loadExit
            QueryExitCode  = $queryExit
            UnloadExitCode = $unloadExit
            LoadOutput     = $loadOutput
            QueryOutput    = $queryOutput
        }
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
    # Crash breadcrumb (run 53): the writer appends one line per step
    # to this file as it goes (see Write-PrivProgress). Run 52 died
    # with STATUS_HEAP_CORRUPTION before the first "wrote" line and
    # the import log came back empty; the progress file survives the
    # crash because each line is a synchronous write, so the failure
    # below can still say how far the import got.
    $progressFile = Join-Path $workDir 'import.progress.txt'
    try {
        @(
            '@echo off',
            "set `"MICPE_PRIV_PROGRESS=$progressFile`"",
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
            # The import log is the first source; the progress file is
            # the second — it holds the per-step lines the writer wrote
            # synchronously before the failure, so it is the only record
            # when the import process itself crashes (run 52: the log
            # came back empty). Both are shown when they differ.
            $detail = '(the privileged import printed nothing)'
            $logText = ''
            if (Test-Path -LiteralPath $logFile) {
                $logText = "$((Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue))".Trim()
            }
            $progressText = ''
            if (Test-Path -LiteralPath $progressFile) {
                $progressText = "$((Get-Content -LiteralPath $progressFile -Raw -ErrorAction SilentlyContinue))".Trim()
            }
            $parts = @()
            if ($logText) { $parts += $logText }
            if ($progressText -and $progressText -ne $logText) {
                $parts += ("progress before the failure:`n" + $progressText)
            }
            if ($parts.Count -gt 0) { $detail = ($parts -join "`n") }
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
        # Run 58: assert every written value landed, same as the SYSTEM
        # path does. Assert-RegImportLanded warns and skips on access
        # denied (it already has that guard), and the ETC/Overrides
        # keys grant KEY_READ to Administrators, so the assert can read
        # back the values through the mounted hive (the hive key is
        # embedded in the .reg path, so no -HiveKey parameter exists).
        Assert-RegImportLanded -RegFile $RegFile
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

function Get-RegFileDeclaredEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RegFile
    )

    # Parses a .reg patch into the sections it declares and the value
    # names each section writes. Names only, never values: the caller
    # (Assert-RegImportLanded) reads the values back from the hive, so
    # a drift between parser and file cannot silently pass. Pure text
    # parsing, no registry access: unit-testable on Linux.
    #
    # Run 55: the 60-werdumps SYSTEM import exited 0 while the values
    # never landed (the key existed, DumpFolder did not) — the import
    # step never read anything back. The parser feeds the read-back
    # that closes that gap.
    Assert-PathExists -Path $RegFile -Label 'Registry patch'

    $text = [System.IO.File]::ReadAllText($RegFile, [System.Text.Encoding]::Unicode)
    $entries = [System.Collections.Generic.List[pscustomobject]]::new()
    $current = $null
    # A value can span lines with a trailing backslash (hex blobs in
    # 40-uwp.reg); the name is always on the first line, so a
    # continuation line matches nothing below and is skipped.
    foreach ($rawLine in ($text -split "`r`n|`n")) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $path = $Matches[1]
            if ($path -notmatch '^HKEY_LOCAL_MACHINE\\(.+)$') {
                throw [System.InvalidOperationException]::new(
                    "registry patch section '$path' does not address HKEY_LOCAL_MACHINE (never write outside the mounted hive)")
            }
            # Run 50 lesson: a section addressing a live hive root
            # (HKLM\SOFTWARE, HKLM\SYSTEM, ...) writes into the
            # runner's live registry, not the mounted image hive.
            # Mounted hives always carry a PE-* (or test) key name.
            $root = $Matches[1].Split('\')[0]
            if ($root -in @('SOFTWARE', 'SYSTEM', 'SAM', 'SECURITY', 'DEFAULT', 'DRIVERS', 'HARDWARE', 'BCD00000000', 'COMPONENTS')) {
                throw [System.InvalidOperationException]::new(
                    "registry patch section '$path' addresses the live $root hive, not a mounted image hive (run 50 lesson: HKLM\$root writes into the runner, not the image)")
            }
            $current = [pscustomobject]@{
                KeyPath = $Matches[1]
                Values  = [System.Collections.Generic.List[string]]::new()
            }
            $entries.Add($current)
            continue
        }
        if ($null -eq $current) { continue }  # header line
        if ($line -match '^"((?:[^"\\]|\\.)*)"\s*=') {
            $name = $Matches[1] -replace '\\\\', '\' -replace '\\"', '"'
            $current.Values.Add($name)
        }
        elseif ($line -match '^@\s*=') {
            $current.Values.Add('(Default)')
        }
    }
    return $entries
}

function Assert-RegImportLanded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RegFile
    )

    # Reads back every section a .reg patch declares, right after the
    # import, and fails loudly when a declared value is missing. Run
    # 54: the 60-werdumps SYSTEM import exited 0 while the values
    # never landed (the key existed, DumpFolder did not) — the import
    # step never read anything back, so the miss stayed silent until
    # the build-time assert caught it. This closes that gap at the
    # import step itself, for every SYSTEM import, not just WER.
    $entries = Get-RegFileDeclaredEntries -RegFile $RegFile
    foreach ($entry in $entries) {
        $sep = $entry.KeyPath.IndexOf('\')
        $hiveKey = $entry.KeyPath.Substring(0, $sep)
        $subKey = $entry.KeyPath.Substring($sep + 1)
        $values = Get-RegistryKeyValues -KeyName $hiveKey -SubKey $subKey
        if ($null -eq $values) {
            # Distinguish "cannot read" from "does not exist": a key
            # whose DACL denies the build admin a read must not fail
            # the build as if the import missed. (The privileged
            # writer's group keys are like that — but those never go
            # through the SYSTEM import, so a denial here is
            # unexpected; warn and skip that key instead of passing
            # silently or failing wrongly.)
            $probe = & reg.exe query "HKLM\$($entry.KeyPath)" 2>&1 | Out-String
            if ($probe -match 'Access is denied') {
                Write-Warn "cannot read back HKLM\$($entry.KeyPath) (access denied); skipping verification for this key"
                continue
            }
            throw [System.InvalidOperationException]::new(
                "SYSTEM import read-back: HKLM\$($entry.KeyPath) does not exist after importing $(Split-Path -Leaf $RegFile) (reg.exe exited 0 but the key never landed)")
        }
        foreach ($name in $entry.Values) {
            if (-not $values.Contains($name)) {
                $have = if ($values.Count -gt 0) { ($values.Keys -join ', ') } else { '(no values)' }
                throw [System.InvalidOperationException]::new(
                    "SYSTEM import read-back: value '$name' is missing under HKLM\$($entry.KeyPath) after importing $(Split-Path -Leaf $RegFile) (reg.exe exited 0; key exists with: $have)")
            }
        }
    }
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

function ConvertTo-HiveRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FullPath
    )

    # Accepts HKLM\... / HKEY_LOCAL_MACHINE\... and returns the part below the
    # root, which is what the registry API expects.
    $text = $FullPath.Trim()
    if ($text -match '^HKLM\\(.+)$') { return $Matches[1] }
    if ($text -match '^HKEY_LOCAL_MACHINE\\(.+)$') { return $Matches[1] }
    throw [System.ArgumentException]::new("Not an HKLM path: $FullPath")
}

# Registry trees from a full Windows image contain keys owned by
# NT SERVICE\TrustedInstaller where Administrators hold only ReadKey - for
# example AppModel\Mappings\S-1-15-2-*. Some are not even readable
# (AppModel\CloudExtensions), so a plain "copy everything" loop either fails
# outright or silently loses a subtree. Copy-RegistryKeyTree therefore repairs
# access on demand (take ownership, grant Administrators, retry once) and
# records anything that still refuses, so a build can report exactly what it
# could not carry over instead of dying on the first locked key.
$script:RegCopyDenied = [System.Collections.Generic.List[string]]::new()
$script:RegCopyUnreadable = [System.Collections.Generic.List[string]]::new()

function Reset-RegistryCopyDenied {
    [CmdletBinding()]
    param()

    $script:RegCopyDenied.Clear()
    $script:RegCopyUnreadable.Clear()
}

function Get-RegistryCopyDenied {
    [CmdletBinding()]
    param()

    # ToArray() (not a comma-wrapped literal): an empty list then yields no
    # pipeline output, so "@(Get-RegistryCopyDenied).Count" is 0 rather than 1.
    return $script:RegCopyDenied.ToArray()
}

function Get-RegistryCopyUnreadable {
    [CmdletBinding()]
    param()

    return $script:RegCopyUnreadable.ToArray()
}

function Test-RegistryAccessException {
    <#
        .SYNOPSIS
            True when an error record means "the ACL said no".

        .DESCRIPTION
            The registry API raises two different shapes for the same condition,
            and PowerShell wraps both in MethodInvocationException:

              * read denial  -> SecurityException      ("Requested registry
                                access is not allowed.")
              * write denial -> UnauthorizedAccessException ("Access to the
                                registry key '...' is denied.")

            Catching only UnauthorizedAccessException misses every read denial,
            which is exactly how AppModel\CloudExtensions broke the chain.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex -is [System.UnauthorizedAccessException] -or
            $ex -is [System.Security.SecurityException]) {
            return $true
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Initialize-RegistryWritePrivileges {
    <#
        .SYNOPSIS
            Compiles the token helper that enables SeTakeOwnershipPrivilege.

        .DESCRIPTION
            An elevated token carries SeTakeOwnershipPrivilege and
            SeRestorePrivilege but leaves them disabled, so
            RegistryRights.TakeOwnership fails with "Requested registry access
            is not allowed." until AdjustTokenPrivileges turns them on. There is
            no managed API for that, hence the tiny P/Invoke shim.
    #>
    [CmdletBinding()]
    param()

    if ('Micpe.RegistryToken' -as [type]) { return }

    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Micpe
{
    public static class RegistryToken
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct Luid { public uint Low; public int High; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenPrivileges
        {
            public uint Count;
            public Luid Privilege;
            public uint Attributes;
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(
            IntPtr token, bool disableAll, ref TokenPrivileges state, uint length,
            IntPtr previous, IntPtr returnLength);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static bool Enable(string name)
        {
            IntPtr token;
            // TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES
            if (!OpenProcessToken(GetCurrentProcess(), 0x0008 | 0x0020, out token)) return false;
            try
            {
                Luid luid;
                if (!LookupPrivilegeValue(null, name, out luid)) return false;
                TokenPrivileges state = new TokenPrivileges();
                state.Count = 1;
                state.Privilege = luid;
                state.Attributes = 0x00000002; // SE_PRIVILEGE_ENABLED
                if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                // AdjustTokenPrivileges returns TRUE even when the privilege was
                // not held; the real answer is ERROR_NOT_ALL_ASSIGNED (1300).
                return Marshal.GetLastWin32Error() == 0;
            }
            finally
            {
                CloseHandle(token);
            }
        }
    }
}
'@
}

function Repair-RegistryKeyAccess {
    <#
        .SYNOPSIS
            Takes ownership of one key and grants Administrators full control.

        .DESCRIPTION
            Used when a read or a write hits a TrustedInstaller-owned key.
            Ownership goes to BUILTIN\Administrators, then a FullControl ACE with
            container inheritance is added so everything underneath stays
            accessible. Only keys that actually refused access are touched, so a
            normal copy leaves the image ACLs alone.

            Repairing a key inside the scratch source hive is harmless (that hive
            is re-extracted every build); repairing one inside the mounted image
            is what the servicing stack does when it takes over a package key.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $FullPath)

    Initialize-RegistryWritePrivileges
    $null = [Micpe.RegistryToken]::Enable('SeTakeOwnershipPrivilege')
    $null = [Micpe.RegistryToken]::Enable('SeRestorePrivilege')

    $sub = ConvertTo-HiveRelativePath -FullPath $FullPath
    $admins = [System.Security.Principal.NTAccount]::new('BUILTIN', 'Administrators')
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $ownerKey = $null
        try {
            $ownerKey = $root.OpenSubKey($sub,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        }
        catch {
            $ownerKey = $null
        }
        if ($null -eq $ownerKey) {
            return $false
        }
        try {
            $security = [Microsoft.Win32.RegistryAclExtensions]::GetAccessControl(
                $ownerKey, [System.Security.AccessControl.AccessControlSections]::Owner)
            $security.SetOwner($admins)
            [Microsoft.Win32.RegistryAclExtensions]::SetAccessControl($ownerKey, $security)
        }
        finally {
            $ownerKey.Dispose()
        }

        # Ownership alone grants nothing: reopen for WRITE_DAC and add the ACE.
        $daclKey = $null
        try {
            $daclKey = $root.OpenSubKey($sub,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        }
        catch {
            $daclKey = $null
        }
        if ($null -eq $daclKey) {
            return $false
        }
        try {
            $security = [Microsoft.Win32.RegistryAclExtensions]::GetAccessControl(
                $daclKey,
                [System.Security.AccessControl.AccessControlSections]::Access)
            $rule = [System.Security.AccessControl.RegistryAccessRule]::new(
                $admins,
                [System.Security.AccessControl.RegistryRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $security.AddAccessRule($rule)
            [Microsoft.Win32.RegistryAclExtensions]::SetAccessControl($daclKey, $security)
        }
        finally {
            $daclKey.Dispose()
        }
    }
    catch {
        Write-Warn ("access repair failed: {0} ({1})" -f $FullPath, $_.Exception.Message)
        return $false
    }
    finally {
        $root.Dispose()
    }

    Write-SubStep ("took ownership of {0}" -f $FullPath)
    return $true
}

function Open-RegistrySubKeyWithRepair {
    <#
        .SYNOPSIS
            Opens a subkey read-only, repairing the ACL once if it refuses.

        .DESCRIPTION
            Returns @{ Key; Status } with Status = ok | missing | denied, so the
            caller can tell "this build does not have the key" (skip quietly)
            from "the ACL refused even after repair" (report it).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Microsoft.Win32.RegistryKey] $Parent,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $FullPath
    )

    try {
        $key = $Parent.OpenSubKey($Name, $false)
        if ($null -ne $key) { return [pscustomobject]@{ Key = $key; Status = 'ok' } }
        # No exception and no key: the key is simply not in this image.
        return [pscustomobject]@{ Key = $null; Status = 'missing' }
    }
    catch {
        if (-not (Test-RegistryAccessException -ErrorRecord $_)) { throw }
        if (-not (Repair-RegistryKeyAccess -FullPath $FullPath)) {
            return [pscustomobject]@{ Key = $null; Status = 'denied' }
        }
        try {
            $key = $Parent.OpenSubKey($Name, $false)
            if ($null -ne $key) { return [pscustomobject]@{ Key = $key; Status = 'ok' } }
            return [pscustomobject]@{ Key = $null; Status = 'missing' }
        }
        catch {
            return [pscustomobject]@{ Key = $null; Status = 'denied' }
        }
    }
}

function Copy-RegistryKeyNode {
    <#
        .SYNOPSIS
            Recursively copies values and subkeys of one key pair.

        .DESCRIPTION
            Paths are passed in explicitly instead of read back from
            RegistryKey.Name: after a denied call the handle may already be
            disposed and Name comes back empty, which turns a useful warning into
            an unreadable one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Microsoft.Win32.RegistryKey] $Source,
        [Parameter(Mandatory = $true)] [Microsoft.Win32.RegistryKey] $Target,
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $TargetPath
    )

    # Values first: SetValue with the source's own kind keeps REG_NONE,
    # REG_BINARY, REG_DWORD, REG_QWORD, REG_SZ, REG_EXPAND_SZ and REG_MULTI_SZ
    # byte-for-byte identical. DoNotExpandEnvironmentNames stops the API from
    # resolving %SystemRoot% into the build host's path.
    try {
        foreach ($valueName in $Source.GetValueNames()) {
            $kind = $Source.GetValueKind($valueName)
            $data = $Source.GetValue($valueName, $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $data) {
                # Zero-length REG_NONE / REG_BINARY reads back as $null.
                $data = [byte[]]::new(0)
            }
            $Target.SetValue($valueName, $data, $kind)
        }
    }
    catch {
        if (-not (Test-RegistryAccessException -ErrorRecord $_)) { throw }
        $script:RegCopyDenied.Add($TargetPath)
        Write-Warn ("values refused by {0}, key left as-is" -f $TargetPath)
    }

    foreach ($subName in $Source.GetSubKeyNames()) {
        $childSource = "$SourcePath\$subName"
        $childTarget = "$TargetPath\$subName"

        $probe = Open-RegistrySubKeyWithRepair -Parent $Source -Name $subName -FullPath $childSource
        if ($probe.Status -ne 'ok') {
            # 'missing' is normal (the key is not in this build); only 'denied'
            # means the ACL won even after the ownership repair.
            if ($probe.Status -eq 'denied') {
                $script:RegCopyUnreadable.Add($childSource)
                Write-Warn ("source unreadable, subtree skipped: {0}" -f $childSource)
            }
            continue
        }
        $sourceSub = $probe.Key
        try {
            $targetSub = $null
            try {
                $targetSub = $Target.CreateSubKey($subName, $true)
            }
            catch {
                if (-not (Test-RegistryAccessException -ErrorRecord $_)) { throw }
                # The child already exists with a DACL that keeps Administrators
                # read-only (AppModel\Mappings\S-1-15-*). Take ownership of that
                # exact key, then retry once.
                if (Repair-RegistryKeyAccess -FullPath $childTarget) {
                    try {
                        $targetSub = $Target.CreateSubKey($subName, $true)
                    }
                    catch {
                        $targetSub = $null
                    }
                }
                if ($null -eq $targetSub) {
                    $script:RegCopyDenied.Add($childTarget)
                    Write-Warn ("access denied, subtree left as-is: {0}" -f $childTarget)
                    continue
                }
            }

            if ($null -eq $targetSub) {
                $script:RegCopyDenied.Add($childTarget)
                continue
            }
            try {
                Copy-RegistryKeyNode -Source $sourceSub -Target $targetSub `
                    -SourcePath $childSource -TargetPath $childTarget
            }
            finally {
                $targetSub.Dispose()
            }
        }
        finally {
            $sourceSub.Dispose()
        }
    }
}

function Copy-RegistryKeyTree {
    <#
        .SYNOPSIS
            Copies one key, every subkey and every value into another hive.

        .DESCRIPTION
            WimBuilder2's RegCopy is "reg export -> rewrite the root -> reg
            import". That text round-trip breaks on this image:

              * reg.exe wraps a key path at ~100 columns WITHOUT a continuation
                backslash, so an exported key such as
                ...\AppModel\SystemAppData\windows.immersivecontrolpanel_cw5...
                comes back as two physical lines and reg import rejects the whole
                file with exit code 1 (build 2026-11-22 12:33);
              * keys under AppModel are owned by TrustedInstaller and some
                (AppModel\CloudExtensions) are not even readable by
                Administrators, so import is denied there no matter how the text
                is formatted.

            Walking the tree through the registry API drops the text layer (value
            names, value kinds, the default value and the subkey structure are
            copied as they are) and lets a locked key be repaired on the spot:
            take ownership, grant Administrators, retry. Anything that still
            refuses is recorded in $script:RegCopyDenied / $script:RegCopyUnreadable
            and the copy continues, so one locked subkey cannot abort a build.

            Both hives must already be loaded (Mount-RegistryHive) and both paths
            are absolute under HKLM, e.g. HKLM\PE-SRC-SOFT\Classes\Local Settings
            \... . Returns $false when the source key is absent or unreadable, so
            the caller can report it exactly like a failed reg export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $TargetPath
    )

    $sourceSub = ConvertTo-HiveRelativePath -FullPath $SourcePath
    $targetSub = ConvertTo-HiveRelativePath -FullPath $TargetPath

    # Pin the 64-bit view: a 32-bit host would otherwise redirect and we would
    # copy into WOW6432Node without noticing.
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $probe = Open-RegistrySubKeyWithRepair -Parent $root -Name $sourceSub -FullPath $SourcePath
        if ($probe.Status -ne 'ok') {
            if ($probe.Status -eq 'denied') { $script:RegCopyUnreadable.Add($SourcePath) }
            return $false
        }
        $sourceKey = $probe.Key
        try {
            $targetKey = $null
            try {
                $targetKey = $root.CreateSubKey($targetSub, $true)
            }
            catch {
                if (-not (Test-RegistryAccessException -ErrorRecord $_)) { throw }
                if (Repair-RegistryKeyAccess -FullPath $TargetPath) {
                    $targetKey = $root.CreateSubKey($targetSub, $true)
                }
            }
            if ($null -eq $targetKey) {
                throw [System.InvalidOperationException]::new("cannot create target key: $TargetPath")
            }
            try {
                Copy-RegistryKeyNode -Source $sourceKey -Target $targetKey `
                    -SourcePath $SourcePath -TargetPath $TargetPath
            }
            finally {
                $targetKey.Dispose()
            }
        }
        finally {
            $sourceKey.Dispose()
        }
    }
    finally {
        $root.Dispose()
    }

    return $true
}
