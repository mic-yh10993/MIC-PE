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

    This script writes the same patch a different way, in two steps.
    First it enables SeBackupPrivilege and SeRestorePrivilege in its own
    token and opens the keys with REG_OPTION_BACKUP_RESTORE: under
    backup/restore semantics the kernel skips the key DACL and checks
    only the privilege, so a caller holding SeRestorePrivilege can
    create the feature subkey where SYSTEM's DACL alone cannot. Second,
    the values are written through an ordinary handle. That split is
    forced by run 52: RegSetValueEx through a backup/restore handle
    returns success but the values never land — the key is created,
    empty, and a later read-back finds nothing there. So the new subkey
    is created with an explicit DACL (SYSTEM, Administrators and the
    Feature Management service account, all full control) instead of
    inheriting the group key's read-only DACL, and the values go in
    through a normal RegOpenKeyEx. It is the same mechanism backup
    software uses for the create; it does not change any DACL of a
    stock key (the group keys and every stock entry keep theirs) —
    only the new subkey, which has no stock DACL to preserve, carries
    the explicit one.

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
    // Run 58 (ETC temp-layer experiment): the DACL save/write/restore
    // flow needs these. DACL_SECURITY_INFORMATION asks RegGetKeySecurity
    // / RegSetKeySecurity for the DACL only (owner/group/SACL untouched).
    // WRITE_DAC + READ_CONTROL open the key for the DACL swap through a
    // backup/restore handle, which skips the key DACL and checks only
    // the privilege — the same mechanism backup software uses.
    public const uint DACL_SECURITY_INFORMATION = 0x00000004;
    public const uint WRITE_DAC = 0x00040000;
    public const uint READ_CONTROL = 0x00020000;
    public const int ERROR_ACCESS_DENIED = 5;
    public const int ERROR_INSUFFICIENT_BUFFER = 122;
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
    public static extern int RegSetValueEx(UIntPtr hKey, string lpValueName, uint Reserved, uint dwType, byte[] lpData, uint cbData);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(UIntPtr hKey);

    // Run 58 (ETC temp-layer experiment): read and replace a key's
    // DACL. RegGetKeySecurity returns the descriptor in self-relative
    // format, so the bytes are self-contained and can be handed back
    // to RegSetKeySecurity verbatim for the restore.
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegGetKeySecurity(UIntPtr hKey, uint SecurityInformation, byte[] pSecurityDescriptor, ref uint lpcbSecurityDescriptor);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegSetKeySecurity(UIntPtr hKey, uint SecurityInformation, byte[] pSecurityDescriptor);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertStringSidToSid(string StringSid, out IntPtr Sid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint GetLengthSid(IntPtr pSid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool InitializeSecurityDescriptor(IntPtr pSecurityDescriptor, uint dwRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool SetSecurityDescriptorDacl(IntPtr pSecurityDescriptor, bool bDaclPresent, IntPtr pDacl, bool bDaclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool InitializeAcl(IntPtr pAcl, uint nAclLength, uint dwAclRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AddAccessAllowedAce(IntPtr pAcl, uint dwAceRevision, uint AccessMask, IntPtr pSid);

    // SECURITY_DESCRIPTOR in absolute format: a 4-byte header
    // (Revision, Sbz1, Control) followed by four pointers. On x64
    // that is 40 bytes, not 20: the run 52 code allocated 20 bytes
    // (the x86 size), so InitializeSecurityDescriptor wrote 20 bytes
    // past the buffer on every CreateKeyWithDacl and corrupted the
    // heap — run 53 reproduced it deterministically, crashing on the
    // third call with STATUS_HEAP_CORRUPTION. Size the buffer from
    // the struct so the allocation is right on any pointer width.
    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_DESCRIPTOR
    {
        public byte Revision;
        public byte Sbz1;
        public ushort Control;
        public IntPtr Owner;
        public IntPtr Group;
        public IntPtr Sacl;
        public IntPtr Dacl;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES
    {
        public uint nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "RegCreateKeyExW")]
    public static extern int RegCreateKeyExWithSA(UIntPtr hKey, string lpSubKey, uint Reserved, string lpClass, uint dwOptions, uint samDesired, ref SECURITY_ATTRIBUTES lpSecurityAttributes, out UIntPtr phkResult, out uint lpdwDisposition);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr hMem);

    // Creates a subkey with an explicit DACL instead of inheriting its
    // parent's. Feature override subkeys are created under group keys
    // whose DACL gives SYSTEM only KEY_READ, so a key created the
    // ordinary way inherits that DACL and nobody can write its values
    // — run 52 proved it: RegSetValueEx through a backup/restore handle
    // returned success but the values never landed (the key existed,
    // empty, afterwards). The new key carries SYSTEM, Administrators
    // and the Feature Management service account, all full control, so
    // the values are written afterwards through an ordinary handle.
    // The group keys and every stock entry keep their DACL; only this
    // new subkey carries the explicit DACL. Throws InvalidOperationException
    // naming the failed step; the caller turns it into a build failure.
    public static void CreateKeyWithDacl(UIntPtr hParent, string subKey, out UIntPtr phkResult)
    {
        phkResult = UIntPtr.Zero;
        IntPtr pSystemSid = IntPtr.Zero;
        IntPtr pAdminSid = IntPtr.Zero;
        IntPtr pServiceSid = IntPtr.Zero;
        IntPtr pAcl = IntPtr.Zero;
        IntPtr pSD = IntPtr.Zero;
        try
        {
            if (!ConvertStringSidToSid("S-1-5-18", out pSystemSid))
                throw new InvalidOperationException("ConvertStringSidToSid failed for S-1-5-18 with Win32 error " + Marshal.GetLastWin32Error());
            if (!ConvertStringSidToSid("S-1-5-32-544", out pAdminSid))
                throw new InvalidOperationException("ConvertStringSidToSid failed for S-1-5-32-544 with Win32 error " + Marshal.GetLastWin32Error());
            // Feature Management service account (eval card §37.4: the
            // only account with full control on the group keys). If the
            // SID ever differs in another image, the ACE simply never
            // matches a token; the SYSTEM and Administrators ACEs still
            // apply.
            if (!ConvertStringSidToSid("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464", out pServiceSid))
                throw new InvalidOperationException("ConvertStringSidToSid failed for the Feature Management service SID with Win32 error " + Marshal.GetLastWin32Error());
            uint aclSize = 8 + (8 + GetLengthSid(pSystemSid)) + (8 + GetLengthSid(pAdminSid)) + (8 + GetLengthSid(pServiceSid));
            pAcl = Marshal.AllocHGlobal((int)aclSize);
            if (!InitializeAcl(pAcl, aclSize, 2))
                throw new InvalidOperationException("InitializeAcl failed with Win32 error " + Marshal.GetLastWin32Error());
            if (!AddAccessAllowedAce(pAcl, 2, 0x000f003f, pSystemSid))
                throw new InvalidOperationException("AddAccessAllowedAce failed for SYSTEM with Win32 error " + Marshal.GetLastWin32Error());
            if (!AddAccessAllowedAce(pAcl, 2, 0x000f003f, pAdminSid))
                throw new InvalidOperationException("AddAccessAllowedAce failed for Administrators with Win32 error " + Marshal.GetLastWin32Error());
            if (!AddAccessAllowedAce(pAcl, 2, 0x000f003f, pServiceSid))
                throw new InvalidOperationException("AddAccessAllowedAce failed for the Feature Management service with Win32 error " + Marshal.GetLastWin32Error());
            pSD = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SECURITY_DESCRIPTOR)));
            if (!InitializeSecurityDescriptor(pSD, 1))
                throw new InvalidOperationException("InitializeSecurityDescriptor failed with Win32 error " + Marshal.GetLastWin32Error());
            if (!SetSecurityDescriptorDacl(pSD, true, pAcl, false))
                throw new InvalidOperationException("SetSecurityDescriptorDacl failed with Win32 error " + Marshal.GetLastWin32Error());
            SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
            sa.nLength = (uint)Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            sa.lpSecurityDescriptor = pSD;
            sa.bInheritHandle = false;
            uint disposition = 0;
            int rc = RegCreateKeyExWithSA(hParent, subKey, 0, null, REG_OPTION_BACKUP_RESTORE, 0x000f003f, ref sa, out phkResult, out disposition);
            if (rc != 0)
                throw new InvalidOperationException("RegCreateKeyEx failed for '" + subKey + "' with Win32 error " + rc);
        }
        finally
        {
            if (pSD != IntPtr.Zero) Marshal.FreeHGlobal(pSD);
            if (pAcl != IntPtr.Zero) Marshal.FreeHGlobal(pAcl);
            if (pSystemSid != IntPtr.Zero) LocalFree(pSystemSid);
            if (pAdminSid != IntPtr.Zero) LocalFree(pAdminSid);
            if (pServiceSid != IntPtr.Zero) LocalFree(pServiceSid);
        }
    }

    // Run 58 (ETC temp-layer experiment): read a key's DACL as
    // self-relative bytes. Two-call pattern: the first call with a null
    // buffer returns ERROR_INSUFFICIENT_BUFFER and the required size.
    // The bytes are self-contained, so the caller can hand them back
    // to SetKeySecurityDacl verbatim for the restore. Throws
    // InvalidOperationException naming the failed step.
    public static byte[] GetKeySecurityDacl(UIntPtr hKey)
    {
        uint size = 0;
        int rc = RegGetKeySecurity(hKey, DACL_SECURITY_INFORMATION, null, ref size);
        if (rc != ERROR_INSUFFICIENT_BUFFER)
            throw new InvalidOperationException("RegGetKeySecurity (size probe) failed with Win32 error " + rc);
        byte[] sd = new byte[size];
        rc = RegGetKeySecurity(hKey, DACL_SECURITY_INFORMATION, sd, ref size);
        if (rc != 0)
            throw new InvalidOperationException("RegGetKeySecurity failed with Win32 error " + rc);
        return sd;
    }

    // Run 58: replace a key's DACL with the saved bytes (self-relative,
    // as returned by GetKeySecurityDacl). Throws InvalidOperationException
    // naming the failed step.
    public static void SetKeySecurityDacl(UIntPtr hKey, byte[] sd)
    {
        int rc = RegSetKeySecurity(hKey, DACL_SECURITY_INFORMATION, sd);
        if (rc != 0)
            throw new InvalidOperationException("RegSetKeySecurity failed with Win32 error " + rc);
    }

    // Run 58: convert an absolute security descriptor to self-relative
    // bytes (the form RegSetKeySecurity takes as a byte[]).
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool MakeSelfRelativeSD(IntPtr pAbsoluteSD, byte[] pSelfRelativeSD, ref uint lpdwBufferLength);

    // Run 58: set a key's DACL to a transient one-ACE descriptor (SYSTEM
    // full control only) so the caller can write values through an
    // ordinary handle. The descriptor is built in absolute format,
    // converted to self-relative bytes, and applied before any of its
    // buffers are freed. The caller must restore the saved DACL
    // afterwards and verify the restore; this method does not keep the
    // transient DACL around. Throws InvalidOperationException naming
    // the failed step.
    public static void SetTransientSystemDacl(UIntPtr hKey)
    {
        IntPtr pSystemSid = IntPtr.Zero;
        IntPtr pAcl = IntPtr.Zero;
        IntPtr pSD = IntPtr.Zero;
        try
        {
            if (!ConvertStringSidToSid("S-1-5-18", out pSystemSid))
                throw new InvalidOperationException("ConvertStringSidToSid failed for S-1-5-18 with Win32 error " + Marshal.GetLastWin32Error());
            uint aclSize = 8 + (8 + GetLengthSid(pSystemSid));
            pAcl = Marshal.AllocHGlobal((int)aclSize);
            if (!InitializeAcl(pAcl, aclSize, 2))
                throw new InvalidOperationException("InitializeAcl failed with Win32 error " + Marshal.GetLastWin32Error());
            if (!AddAccessAllowedAce(pAcl, 2, 0x000f003f, pSystemSid))
                throw new InvalidOperationException("AddAccessAllowedAce failed for SYSTEM with Win32 error " + Marshal.GetLastWin32Error());
            pSD = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SECURITY_DESCRIPTOR)));
            if (!InitializeSecurityDescriptor(pSD, 1))
                throw new InvalidOperationException("InitializeSecurityDescriptor failed with Win32 error " + Marshal.GetLastWin32Error());
            if (!SetSecurityDescriptorDacl(pSD, true, pAcl, false))
                throw new InvalidOperationException("SetSecurityDescriptorDacl failed with Win32 error " + Marshal.GetLastWin32Error());
            uint sdSize = 0;
            if (MakeSelfRelativeSD(pSD, null, ref sdSize))
                throw new InvalidOperationException("MakeSelfRelativeSD (size probe) unexpectedly succeeded");
            if (Marshal.GetLastWin32Error() != ERROR_INSUFFICIENT_BUFFER)
                throw new InvalidOperationException("MakeSelfRelativeSD (size probe) failed with Win32 error " + Marshal.GetLastWin32Error());
            byte[] sd = new byte[sdSize];
            if (!MakeSelfRelativeSD(pSD, sd, ref sdSize))
                throw new InvalidOperationException("MakeSelfRelativeSD failed with Win32 error " + Marshal.GetLastWin32Error());
            int rc = RegSetKeySecurity(hKey, DACL_SECURITY_INFORMATION, sd);
            if (rc != 0)
                throw new InvalidOperationException("RegSetKeySecurity (transient DACL) failed with Win32 error " + rc);
        }
        finally
        {
            if (pSD != IntPtr.Zero) Marshal.FreeHGlobal(pSD);
            if (pAcl != IntPtr.Zero) Marshal.FreeHGlobal(pAcl);
            if (pSystemSid != IntPtr.Zero) LocalFree(pSystemSid);
        }
    }

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@

function Write-PrivProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    # Crash breadcrumb (run 53): every progress line goes to the host
    # (the caller redirects stdout to import.log) AND, when the
    # MICPE_PRIV_PROGRESS file is set, straight to that file with
    # Add-Content — one synchronous write per step. Run 52 died with
    # STATUS_HEAP_CORRUPTION before the first "wrote" line and the
    # import log came back empty, so the next crash must still leave a
    # trail of how far the import got. A progress-file failure must
    # never break the import itself, so it is swallowed here.
    Write-Host $Message
    $progressFile = $env:MICPE_PRIV_PROGRESS
    if ($progressFile) {
        try {
            Add-Content -LiteralPath $progressFile -Value $Message -ErrorAction Stop
        }
        catch {
            # Diagnostics only; the import continues without them.
        }
    }
}

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

function Ensure-PrivilegedRegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SubKeyPath
    )

    # Walk the path one segment at a time under HKLM, opening each key
    # with REG_OPTION_BACKUP_RESTORE (the DACL is skipped; the privilege
    # governs) and creating a segment that does not exist yet. A new
    # segment is created with CreateKeyWithDacl, which gives it an
    # explicit DACL (SYSTEM, Administrators, Feature Management service
    # — full control) instead of inheriting the group key's read-only
    # DACL: run 52 proved a key created the ordinary way keeps the
    # read-only DACL and then nobody can write its values (RegSetValueEx
    # through the backup/restore handle returned success but the values
    # never landed). The key is left existing and closed; the caller
    # re-opens it through an ordinary handle to write the values.
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
            # CreateKeyWithDacl throws naming the failed step.
            [MicpePrivilegedRegistry]::CreateKeyWithDacl($parent, $segment, [ref]$child)
            $rc = 0
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
    if ($parent -ne [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE) {
        [void][MicpePrivilegedRegistry]::RegCloseKey($parent)
    }
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

function Write-PrivilegedRegistryValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyPath,

        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary] $Values
    )

    # Writes the values of one .reg section through an ordinary handle.
    # Two paths: a key the privileged create just made (or any key
    # whose DACL already lets SYSTEM write) takes the fast path; a
    # stock key whose DACL gives SYSTEM only KEY_READ
    # (EnterpriseTempControls, run 58) takes the DACL save/write/
    # restore flow. Any failure throws; the build then discards the
    # mount, so a half-written hive never ships. Returns the number
    # of values written.
    $handle = [UIntPtr]::Zero
    try {
        $rc = [MicpePrivilegedRegistry]::RegOpenKeyEx(
            [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE, $KeyPath, 0,
            [MicpePrivilegedRegistry]::KEY_SET_VALUE -bor [MicpePrivilegedRegistry]::KEY_QUERY_VALUE,
            [ref]$handle)
        if ($rc -eq [MicpePrivilegedRegistry]::ERROR_ACCESS_DENIED) {
            Write-PrivProgress ("key {0} denies ordinary write (access denied); using DACL save/write/restore flow" -f $KeyPath)
            return (Write-PrivilegedRegistryValuesWithDaclFlow -KeyPath $KeyPath -Values $Values)
        }
        if ($rc -ne 0) {
            throw [System.InvalidOperationException]::new(
                "cannot open '$KeyPath' for writing after privileged create (Win32 error $rc) — the new key's DACL may still be restrictive")
        }
        $count = 0
        foreach ($name in $Values.Keys) {
            Set-PrivilegedRegistryValue -KeyHandle $handle -Name $name -Value $Values[$name]
            Write-PrivProgress ("wrote HKLM\{0}\{1} = 0x{2:x8}" -f $KeyPath, $name, $Values[$name])
            $count++
        }
        return $count
    }
    finally {
        if ($handle -ne [UIntPtr]::Zero) {
            [void][MicpePrivilegedRegistry]::RegCloseKey($handle)
        }
    }
}

function Test-RegistryDaclEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SavedSddl,

        [Parameter(Mandatory = $true)]
        [string] $RestoredSddl
    )

    # Compares two DACL SDDL forms for policy equality. The ACE list
    # (the parenthesized groups) is the access policy; the control
    # flags before it describe how the DACL was composed. The kernel
    # clears SE_DACL_AUTO_INHERITED when it stores a protected DACL
    # (a protected DACL has no inherited ACEs, so the bit carries no
    # access meaning — CI run 44709227930: saved D:PAI, restored D:P,
    # same ACEs), so the auto-inherit flags are excluded from the
    # comparison. The protection flag is compared: dropping it would
    # let the key inherit its parent's DACL, which changes the
    # effective access even though the explicit ACEs are the same.
    # Returns $true when the DACLs grant the same access.
    $savedIdx = $SavedSddl.IndexOf('(')
    $restoredIdx = $RestoredSddl.IndexOf('(')
    if ($savedIdx -lt 0 -or $restoredIdx -lt 0) {
        return $SavedSddl -eq $RestoredSddl
    }
    $savedAces = $SavedSddl.Substring($savedIdx)
    $restoredAces = $RestoredSddl.Substring($restoredIdx)
    $savedProtected = $SavedSddl -match '^D:[A-Z]*P'
    $restoredProtected = $RestoredSddl -match '^D:[A-Z]*P'
    return ($savedAces -eq $restoredAces) -and ($savedProtected -eq $restoredProtected)
}

function Write-PrivilegedRegistryValuesWithDaclFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $KeyPath,

        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary] $Values
    )

    # DACL save/write/restore flow (run 58). Opens the key with
    # REG_OPTION_BACKUP_RESTORE (the DACL is skipped; the privilege
    # governs), saves the stock DACL bytes, sets a transient
    # SYSTEM-only DACL, writes the values through an ordinary handle,
    # then restores the saved DACL and verifies the restore by
    # comparing the DACL's ACE list plus its protection state
    # (Test-RegistryDaclEqual; the kernel re-serializes the descriptor
    # on set, so a byte comparison is too strict — CI runs 44707795321
    # and 44709227930). The transient DACL exists only for the duration
    # of the write; the shipped image keeps the stock DACL. Any
    # failure throws (the build discards the mount). Returns the
    # number of values written.
    $privHandle = [UIntPtr]::Zero
    try {
        $rc = [MicpePrivilegedRegistry]::RegOpenKeyEx(
            [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE, $KeyPath,
            [MicpePrivilegedRegistry]::REG_OPTION_BACKUP_RESTORE,
            [MicpePrivilegedRegistry]::WRITE_DAC -bor [MicpePrivilegedRegistry]::READ_CONTROL,
            [ref]$privHandle)
        if ($rc -ne 0) {
            throw [System.InvalidOperationException]::new(
                "cannot open '$KeyPath' with backup/restore for the DACL flow (Win32 error $rc)")
        }
        $savedSd = [MicpePrivilegedRegistry]::GetKeySecurityDacl($privHandle)
        Write-PrivProgress ("saved stock DACL ({0} bytes) for {1}" -f $savedSd.Length, $KeyPath)
        [MicpePrivilegedRegistry]::SetTransientSystemDacl($privHandle)
        Write-PrivProgress ("transient DACL set for {0}" -f $KeyPath)
        $count = 0
        try {
            $handle = [UIntPtr]::Zero
            try {
                $rc = [MicpePrivilegedRegistry]::RegOpenKeyEx(
                    [MicpePrivilegedRegistry]::HKEY_LOCAL_MACHINE, $KeyPath, 0,
                    [MicpePrivilegedRegistry]::KEY_SET_VALUE -bor [MicpePrivilegedRegistry]::KEY_QUERY_VALUE,
                    [ref]$handle)
                if ($rc -ne 0) {
                    throw [System.InvalidOperationException]::new(
                        "cannot open '$KeyPath' for writing after transient DACL (Win32 error $rc)")
                }
                foreach ($name in $Values.Keys) {
                    Set-PrivilegedRegistryValue -KeyHandle $handle -Name $name -Value $Values[$name]
                    Write-PrivProgress ("wrote HKLM\{0}\{1} = 0x{2:x8}" -f $KeyPath, $name, $Values[$name])
                    $count++
                }
            }
            finally {
                if ($handle -ne [UIntPtr]::Zero) {
                    [void][MicpePrivilegedRegistry]::RegCloseKey($handle)
                }
            }
        }
        finally {
            [MicpePrivilegedRegistry]::SetKeySecurityDacl($privHandle, $savedSd)
            $restoredSd = [MicpePrivilegedRegistry]::GetKeySecurityDacl($privHandle)
            # Verify the restore semantically, not byte-for-byte: the
            # kernel re-serializes the descriptor when it stores the
            # DACL, so the read-back bytes can differ from the saved
            # bytes (CI run 44707795321: 72 bytes saved, 72 bytes read
            # back, bytes differ) while the access policy is identical.
            # The SDDL form captures the policy — the DACL's ACEs in
            # order plus its protection state — and
            # Test-RegistryDaclEqual compares those, excluding the
            # auto-inherit flags the kernel clears on a protected DACL
            # (CI run 44709227930: saved D:PAI, restored D:P, same ACEs).
            $savedSddl = ([System.Security.AccessControl.RawSecurityDescriptor]::new($savedSd, 0)).GetSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
            $restoredSddl = ([System.Security.AccessControl.RawSecurityDescriptor]::new($restoredSd, 0)).GetSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
            Write-PrivProgress ("DACL restore check for {0}: saved {1}; restored {2}" -f $KeyPath, $savedSddl, $restoredSddl)
            if (-not (Test-RegistryDaclEqual -SavedSddl $savedSddl -RestoredSddl $restoredSddl)) {
                throw [System.InvalidOperationException]::new(
                    "DACL restore verification failed for '$KeyPath': the DACL after restore differs from the saved stock DACL (saved: $savedSddl; restored: $restoredSddl; $($savedSd.Length) bytes saved, $($restoredSd.Length) bytes read back) — failing the build so the mount is discarded")
            }
            Write-PrivProgress ("stock DACL restored and verified for {0}" -f $KeyPath)
        }
        return $count
    }
    finally {
        if ($privHandle -ne [UIntPtr]::Zero) {
            [void][MicpePrivilegedRegistry]::RegCloseKey($privHandle)
        }
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
    Write-PrivProgress ("parsed {0} key(s) from {1}" -f $entries.Count, (Split-Path -Leaf $RegFile))
    Initialize-PrivilegedRegistryApi
    Write-PrivProgress 'privileged registry API loaded'
    Enable-BackupRestorePrivilege
    Write-PrivProgress 'backup/restore privileges enabled'
    $written = 0
    foreach ($entry in $entries) {
        # Make sure the key exists (creates it with an explicit DACL
        # when missing), then write the values through an ordinary
        # handle: RegSetValueEx through a backup/restore handle returns
        # success but the values never land (run 52), so the write must
        # go through a handle opened the ordinary way — which only works
        # because CreateKeyWithDacl gave the new key a writable DACL.
        Write-PrivProgress ("ensuring key {0}" -f $entry.KeyPath)
        Ensure-PrivilegedRegistryKey -SubKeyPath $entry.KeyPath
        Write-PrivProgress ("key ready {0}" -f $entry.KeyPath)
        $written += Write-PrivilegedRegistryValues -KeyPath $entry.KeyPath -Values $entry.Values
    }
    Write-PrivProgress ("privileged import complete: {0} value(s) in {1} key(s) from {2}" -f $written, $entries.Count, (Split-Path -Leaf $RegFile))
}
