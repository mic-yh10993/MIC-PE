#Requires -Version 7.0
<#
.SYNOPSIS
    Write a .reg patch into a mounted registry hive with backup/restore privileges.

.DESCRIPTION
    Run 51 proved that importing 70-feature-42537950.reg as SYSTEM fails:
    the FeatureManagement group keys (Overrides\0, \15, \9) give SYSTEM only
    0x00020019 (KEY_READ) — no SET_VALUE, no CREATE_SUB_KEY — and only the
    Feature Management service account has full control (eval card §37.4,
    offline SYSTEM hive, hand-parsed SK records). A plain `reg import` as
    SYSTEM therefore dies with "Error accessing the registry" before any
    value lands.

    This script writes the same patch a different way: it enables
    SeBackupPrivilege and SeRestorePrivilege in its own token and opens the
    keys with REG_OPTION_BACKUP_RESTORE. Under backup/restore semantics the
    kernel skips the key DACL and checks only the privilege, so a caller
    holding SeRestorePrivilege can create the feature subkey and write its
    values where SYSTEM's DACL alone cannot. It is the same mechanism
    backup software uses; it does not change any DACL in the shipped
    image (the new subkey inherits the group key's stock read-only DACL,
    exactly like the stock feature entries).

    It runs as SYSTEM through a one-shot scheduled task (see
    Invoke-RegImportPrivileged in Registry.ps1) while the hive is mounted,
    so it is still a CI build-time import only (user decision 2026-11-17
    23:43) — nothing is written to the registry inside the running PE.

    The .reg file is the single source of truth: this script parses it
    (DWORD values only) instead of duplicating the values in code. Every
    section must address the mounted hive named by -HiveKey; anything else
    (a section pointing at the runner's live hive, a non-DWORD value, a
    value outside any section) fails loudly instead of being skipped.

.PARAMETER RegFile
    Path to the .reg patch file (UTF-16LE, Windows Registry Editor 5.00).

.PARAMETER HiveKey
    Name of the mounted hive the patch must address (for example PE-SYS).
    Every section in the .reg file must start with
    HKEY_LOCAL_MACHINE\<HiveKey>\.
#>
[CmdletBinding()]
param(
    [string] $RegFile,

    [string] $HiveKey
)

$script:PrivilegedRegistryApiCode = @'
using System;
using System.Runtime.InteropServices;

public static class MicpePrivilegedRegistry
{
    public const uint REG_OPTION_BACKUP_RESTORE = 0x00000004;
    public const uint KEY_QUERY_VALUE = 0x0001;
    public const uint KEY_SET_VALUE = 0x0002;
    public const uint KEY_CREATE_SUB_KEY = 0x0004;
    public const uint KEY_ENUMERATE_SUB_KEYS = 0x0008;
    public const uint REG_DWORD = 4;
    public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const uint TOKEN_QUERY = 0x0008;
    public const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    public const int ERROR_FILE_NOT_FOUND = 2;
    public const int ERROR_NOT_ALL_ASSIGNED = 1300;
    public static readonly UIntPtr HKEY_LOCAL_MACHINE = new UIntPtr(0x80000002u);

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegOpenKeyEx(UIntPtr hKey, string lpSubKey, uint ulOptions, uint samDesired, out UIntPtr phkResult);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegCreateKeyEx(UIntPtr hKey, string lpSubKey, uint Reserved, string lpClass, uint dwOptions, uint samDesired, IntPtr lpSecurityAttributes, out UIntPtr phkResult, out uint lpdwDisposition);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegSetValueEx(UIntPtr hKey, string lpValueName, uint Reserved, uint dwType, byte[] lpData, uint cbData);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(UIntPtr hKey);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@

function Initialize-PrivilegedRegistryApi {
    [CmdletBinding()]
    param()

    # Add-Type is idempotent-guarded: dot-sourcing this file twice (or
    # once per Pester Describe) must not fail on the redefinition.
    if (-not ([System.Management.Automation.PSTypeName]'MicpePrivilegedRegistry').Type) {
        Add-Type -TypeDefinition $script:PrivilegedRegistryApiCode -ErrorAction Stop
    }
}

function Enable-BackupRestorePrivilege {
    [CmdletBinding()]
    param()

    Initialize-PrivilegedRegistryApi

    $token = [IntPtr]::Zero
    $ok = [MicpePrivilegedRegistry]::OpenProcessToken(
        [MicpePrivilegedRegistry]::GetCurrentProcess(),
        [MicpePrivilegedRegistry]::TOKEN_ADJUST_PRIVILEGES -bor [MicpePrivilegedRegistry]::TOKEN_QUERY,
        [ref]$token)
    if (-not $ok) {
        throw [System.InvalidOperationException]::new(
            "OpenProcessToken failed with Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())")
    }
    try {
        foreach ($name in 'SeBackupPrivilege', 'SeRestorePrivilege') {
            $luid = New-Object 'MicpePrivilegedRegistry+LUID'
            $ok = [MicpePrivilegedRegistry]::LookupPrivilegeValue($null, $name, [ref]$luid)
            if (-not $ok) {
                throw [System.InvalidOperationException]::new(
                    "LookupPrivilegeValue failed for $name with Win32 error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())")
            }
            $entry = New-Object 'MicpePrivilegedRegistry+LUID_AND_ATTRIBUTES'
            $entry.Luid = $luid
            $entry.Attributes = [MicpePrivilegedRegistry]::SE_PRIVILEGE_ENABLED
            $state = New-Object 'MicpePrivilegedRegistry+TOKEN_PRIVILEGES'
            $state.PrivilegeCount = 1
            $state.Privileges = $entry
            $ok = [MicpePrivilegedRegistry]::AdjustTokenPrivileges(
                $token, $false, [ref]$state, 0, [IntPtr]::Zero, [IntPtr]::Zero)
            $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if (-not $ok) {
                throw [System.InvalidOperationException]::new(
                    "AdjustTokenPrivileges failed for $name with Win32 error $lastError")
            }
            if ($lastError -eq [MicpePrivilegedRegistry]::ERROR_NOT_ALL_ASSIGNED) {
                throw [System.InvalidOperationException]::new(
                    "privilege $name is not held by this token, so backup/restore registry writes are unavailable")
            }
        }
    }
    finally {
        if ($token -ne [IntPtr]::Zero) {
            [void][MicpePrivilegedRegistry]::CloseHandle($token)
        }
    }
}

function ConvertFrom-RegFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $HiveKey
    )

    # Pure parser for a .reg patch, kept separate so it is unit-testable
    # without a Windows host. Only DWORD values are supported: the
    # feature override patch carries nothing else, and silently skipping
    # an unsupported line would land a half-applied patch.
    if (-not (Test-Path -LiteralPath $Path)) {
        throw [System.InvalidOperationException]::new("registry patch not found: $Path")
    }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Unicode)
    $entries = @()
    $current = $null
    $lineNo = 0
    foreach ($raw in ($text -split "`n")) {
        $lineNo++
        $line = $raw.TrimEnd("`r").Trim()
        if ($line -eq '' -or $line.StartsWith(';')) { continue }
        if ($line -eq 'Windows Registry Editor Version 5.00') { continue }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $keyPath = $line.Substring(1, $line.Length - 2)
            $prefix = "HKEY_LOCAL_MACHINE\$HiveKey\"
            if (-not $keyPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw [System.InvalidOperationException]::new(
                    "line ${lineNo}: key '$keyPath' is outside the mounted hive 'HKEY_LOCAL_MACHINE\$HiveKey' — refusing to write")
            }
            $current = [pscustomobject]@{
                KeyPath = $keyPath.Substring('HKEY_LOCAL_MACHINE\'.Length)
                Values  = [ordered]@{}
            }
            $entries += $current
            continue
        }
        if ($null -eq $current) {
            throw [System.InvalidOperationException]::new(
                "line ${lineNo}: value outside any key section: $line")
        }
        if ($line -match '^"([^"]+)"=dword:([0-9a-fA-F]{8})$') {
            $current.Values[$Matches[1]] = [Convert]::ToUInt32($Matches[2], 16)
            continue
        }
        throw [System.InvalidOperationException]::new(
            "line ${lineNo}: unsupported registry line (only dword values are supported): $line")
    }
    if ($entries.Count -eq 0) {
        throw [System.InvalidOperationException]::new("no key sections found in $Path")
    }
    return $entries
}

function Open-PrivilegedRegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SubKeyPath
    )

    # Walk the path one segment at a time under HKLM, opening each key
    # with REG_OPTION_BACKUP_RESTORE (the DACL is skipped; the privilege
    # governs) and creating a segment that does not exist yet. The leaf
    # is created the same way, so a missing feature subkey is not an
    # error. Returns an open handle the caller must close.
    $sam = [MicpePrivilegedRegistry]::KEY_QUERY_VALUE -bor
        [MicpePrivilegedRegistry]::KEY_SET_VALUE -bor
        [MicpePrivilegedRegistry]::KEY_CREATE_SUB_KEY -bor
        [MicpePrivilegedRegistry]::KEY_ENUMERATE_SUB_KEYS
    $parent = [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE
    foreach ($segment in ($SubKeyPath -split '\\')) {
        if ($segment -eq '') {
            throw [System.InvalidOperationException]::new(
                "empty path segment in registry key '$SubKeyPath'")
        }
        $child = [UIntPtr]::Zero
        $rc = [MicpePrivilegedRegistry]::RegOpenKeyEx(
            $parent, $segment,
            [MicpePrivilegedRegistry]::REG_OPTION_BACKUP_RESTORE,
            $sam, [ref]$child)
        if ($rc -eq [MicpePrivilegedRegistry]::ERROR_FILE_NOT_FOUND) {
            $disposition = [uint32]0
            $rc = [MicpePrivilegedRegistry]::RegCreateKeyEx(
                $parent, $segment, 0, $null,
                [MicpePrivilegedRegistry]::REG_OPTION_BACKUP_RESTORE,
                $sam, [IntPtr]::Zero, [ref]$child, [ref]$disposition)
        }
        if ($rc -ne 0) {
            if ($parent -ne [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE) {
                [void][MicpePrivilegedRegistry]::RegCloseKey($parent)
            }
            throw [System.InvalidOperationException]::new(
                "cannot open or create registry key segment '$segment' in '$SubKeyPath' (Win32 error $rc)")
        }
        if ($parent -ne [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE) {
            [void][MicpePrivilegedRegistry]::RegCloseKey($parent)
        }
        $parent = $child
    }
    return $parent
}

function Set-PrivilegedRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [UIntPtr] $KeyHandle,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [uint32] $Value
    )

    $bytes = [System.BitConverter]::GetBytes($Value)
    $rc = [MicpePrivilegedRegistry]::RegSetValueEx(
        $KeyHandle, $Name, 0,
        [MicpePrivilegedRegistry]::REG_DWORD, $bytes, $bytes.Length)
    if ($rc -ne 0) {
        throw [System.InvalidOperationException]::new(
            "RegSetValueEx failed for '$Name' (Win32 error $rc)")
    }
}

# The parameters are deliberately not mandatory: Pester dot-sources this
# file to test the parser, and a mandatory parameter would prompt for
# input on dot-source and hang the suite. The main flow below validates
# them instead, and it only runs when the file is executed as a script.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    if (-not $IsWindows) {
        throw 'Invoke-PrivilegedRegImport.ps1 needs Windows: it writes a mounted registry hive with backup/restore privileges (advapi32)'
    }
    if (-not $RegFile) {
        throw 'Invoke-PrivilegedRegImport.ps1 needs -RegFile (path to the .reg patch)'
    }
    if (-not $HiveKey) {
        throw 'Invoke-PrivilegedRegImport.ps1 needs -HiveKey (name of the mounted hive the patch addresses)'
    }

    $entries = ConvertFrom-RegFile -Path $RegFile -HiveKey $HiveKey
    Initialize-PrivilegedRegistryApi
    Enable-BackupRestorePrivilege
    $written = 0
    foreach ($entry in $entries) {
        $handle = [UIntPtr]::Zero
        try {
            $handle = Open-PrivilegedRegistryKey -SubKeyPath $entry.KeyPath
            foreach ($name in $entry.Values.Keys) {
                Set-PrivilegedRegistryValue -KeyHandle $handle -Name $name -Value $entry.Values[$name]
                Write-Host ("wrote HKLM\{0}\{1} = 0x{2:x8}" -f $entry.KeyPath, $name, $entry.Values[$name])
                $written++
            }
        }
        finally {
            if ($handle -ne [UIntPtr]::Zero) {
                [void][MicpePrivilegedRegistry]::RegCloseKey($handle)
            }
        }
    }
    Write-Host ("privileged import complete: {0} value(s) in {1} key(s) from {2}" -f $written, $entries.Count, (Split-Path -Leaf $RegFile))
}
