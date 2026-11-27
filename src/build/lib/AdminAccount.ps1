#Requires -Version 7.0
<#
.SYNOPSIS
    Offline SAM surgery for the native logon image.

.DESCRIPTION
    The image must boot straight into a real logon (SystemSetupInProgress=0,
    see src/registry/26-native-logon.reg). WinPE ships the built-in
    Administrator DISABLED, and on a wim-booted system a runtime
    `net user /active:yes` is useless: every write lands in the RAM overlay
    and is discarded on reboot. The account therefore has to be enabled in
    the image itself, at build time.

    Only SYSTEM can write the SAM key, so the read-modify-write runs as
    SYSTEM through a one-shot scheduled task - the same mechanism
    Invoke-RegImportAsSystem uses in Registry.ps1.

    The account is addressed by its RID hex (Users\<RID>), not by name:
    the F value lives on the RID key. The default is the built-in
    Administrator (RID 500, 000001F4); the clean rebuild seeds its SAM
    from a specialize run whose logon account is MICPE (RID 1000,
    000003E8), so the build passes that RID explicitly.
#>

function Set-OfflineAdminState {
    [CmdletBinding()]
    param(
        # SAM hive file inside the mounted image.
        [Parameter(Mandatory = $true)]
        [string] $SamPath,

        [string] $AccountName = 'Administrator',

        # RID hex of the account to enable (000001F4 = built-in
        # Administrator, 000003E8 = first UserAccounts admin, MICPE).
        [string] $RidHex = '000001F4',

        [int] $TimeoutSeconds = 120
    )

    # ACB flags live in the F value of SAM\Domains\Account\Users\<RID>:
    # a DWORD at offset 0x38, ACB_DISABLED = 0x0001. The reference RAMOS
    # image that boots to a real LogonUI carries 0x0210 there
    # (ACB_NORMAL | ACB_PWNOEXP), i.e. enabled.
    Assert-PathExists -Path $SamPath -Label 'SAM hive'

    if ($null -eq (Get-Command -Name 'schtasks.exe' -ErrorAction SilentlyContinue)) {
        throw [System.InvalidOperationException]::new(
            'schtasks.exe is not available: enabling the offline Administrator needs Windows')
    }

    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $hiveKey = "MICPE_SAM_$suffix"
    $fullKey = "HKLM\$hiveKey"
    $taskName = "MICPE-AdminEnable-$suffix"
    $workDir = Join-Path $env:ProgramData $taskName
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    $loader = Join-Path $workDir 'enable-admin.ps1'
    $codeFile = Join-Path $workDir 'exitcode.txt'
    $logFile = Join-Path $workDir 'enable-admin.log'
    $scriptPath = Join-Path $workDir 'run-enable.cmd'

    $loaded = $false
    try {
        $loadOut = & reg.exe load $fullKey $SamPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "could not load the offline SAM hive $SamPath : $($loadOut.Trim())")
        }
        $loaded = $true

        $body = @'
$ErrorActionPreference = 'Stop'
$key = 'Registry::HKEY_LOCAL_MACHINE\__HIVE__\SAM\Domains\Account\Users\__RID__'
$out = @()
try {
    if (-not (Test-Path -LiteralPath $key)) {
        $out += 'found=0'
    }
    else {
        $item = Get-Item -LiteralPath $key
        $f = $item.GetValue('F', $null, 'DoNotExpandEnvironmentNames')
        if ($null -eq $f -or $f.Length -lt 0x40) {
            $out += 'found=1'
            $out += 'error=F value is shorter than 0x40 bytes'
        }
        else {
            $flags = [BitConverter]::ToUInt32($f, 0x38)
            $new = $flags -band (-bnot 0x00000001)
            if ($new -ne $flags) {
                [BitConverter]::GetBytes([uint32]$new).CopyTo($f, 0x38)
                Set-ItemProperty -LiteralPath $key -Name 'F' -Value $f -Type Binary
            }
            $out += 'found=1'
            $out += ('flags=0x{0:X8}' -f $flags)
            $out += ('newflags=0x{0:X8}' -f $new)
        }
    }
}
catch {
    $out += ('error=' + $_.Exception.Message)
}
$out | Set-Content -LiteralPath '__LOG__' -Encoding ascii
'@
        $body = $body.Replace('__HIVE__', $hiveKey).Replace('__LOG__', $logFile).Replace('__RID__', $RidHex)
        Set-Content -LiteralPath $loader -Value $body -Encoding utf8

        @(
            '@echo off',
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$loader`" > `"$logFile.console`" 2>&1",
            "echo %ERRORLEVEL% > `"$codeFile`""
        ) | Set-Content -LiteralPath $scriptPath -Encoding ascii

        # A /sc once task needs a start time; the schedule never fires, the
        # task is triggered with /run right away (same trick as Registry.ps1).
        $startAt = (Get-Date).AddMinutes(2).ToString('HH:mm')
        $create = & schtasks.exe /create /tn $taskName /tr "`"$scriptPath`"" /sc once /st $startAt /ru SYSTEM /rl highest /f 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new(
                "failed to create SYSTEM admin-enable task $taskName : $($create.Trim())")
        }
        $null = & schtasks.exe /run /tn $taskName 2>&1

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path -LiteralPath $codeFile)) {
            if ((Get-Date) -gt $deadline) {
                throw [System.InvalidOperationException]::new(
                    "offline admin-enable did not finish within $TimeoutSeconds seconds (task $taskName)")
            }
            Start-Sleep -Seconds 1
        }
        Start-Sleep -Milliseconds 300

        $lines = @()
        if (Test-Path -LiteralPath $logFile) {
            $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })
        }
        foreach ($line in $lines) { Write-SubStep "sam: $line" }

        $err = $lines | Where-Object { $_ -like 'error=*' } | Select-Object -First 1
        if ($err) {
            throw [System.InvalidOperationException]::new(
                "offline admin-enable failed (HKLM\$hiveKey): $err")
        }
        if ($lines -notcontains 'found=1') {
            # MEASURED (round 41): the install.wim SAM is an EMPTY hive
            # (8 KB, no subkeys at all) -- and the SAM service does NOT
            # create the built-in accounts at boot (r116 died on
            # 0xc00002e3). An empty hive here means the seed step did
            # not populate staging; the caller treats that as fatal.
            # (The old comment claiming the service creates the
            # accounts was disproved by round 41 and is removed.)
            Write-Warn "the image SAM is an empty hive (no $AccountName record): the SAM service does NOT create accounts at boot -- the seed step must have populated it"
            return [pscustomobject]@{
                Found     = $false
                FlagsLine = 'empty SAM hive'
                Flags     = $null
            }
        }

        $newFlagsLine = $lines | Where-Object { $_ -like 'newflags=*' } | Select-Object -First 1
        if (-not $newFlagsLine) {
            throw [System.InvalidOperationException]::new(
                'offline admin-enable produced no flag read-back: the SAM write is unverified')
        }
        $value = [Convert]::ToUInt32(($newFlagsLine -replace '^newflags=', ''), 16)
        if (($value -band 0x1) -ne 0) {
            throw [System.InvalidOperationException]::new(
                "the offline $AccountName is still flagged disabled ($newFlagsLine)")
        }

        Write-SubStep "$AccountName enabled in the offline SAM ($($lines -join ', '))"
        return [pscustomobject]@{
            Found     = $true
            FlagsLine = ($lines -join '; ')
            Flags     = $value
        }
    }
    finally {
        $null = & schtasks.exe /delete /tn $taskName /f 2>&1
        if ($loaded) {
            $null = & reg.exe unload $fullKey 2>&1
        }
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
