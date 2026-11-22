#Requires -Version 5.1
<#
.SYNOPSIS
    Import the WimBuilder2 UWP build chain into MICPE's declarative asset tree.

.DESCRIPTION
    WimBuilder2 drives its PE builds from .bat files that mix three things:

        1. AddFiles file lists      `@\Windows\System32\` + bare file names
        2. RegCopy / RegCopyEx      copy a whole key (or a service key) from the
                                    source hives into the target hives
        3. reg add / reg import     literal values

    This script reads the WIN10XPE project of a WimBuilder2 release, evaluates
    its `+ver` / `+if` dialect against the profile this project was built with
    (UWP default, shell = Explorer, UWP components on, Shell start menu off), and
    emits a flat asset tree that MICPE's own PowerShell build consumes without
    WimBuilder2 being installed:

        src/uwp/filelists/*.txt          one file per AddFiles block
        src/uwp/reg/copy/services.txt    service keys to copy
        src/uwp/reg/copy/keys.txt        registry keys to copy verbatim
        src/uwp/reg/copy/report.txt      provenance for the audit trail

    Only machine-translatable material is generated, so re-running the importer
    is always safe; hand-written values and runtime scripts live elsewhere.

.PARAMETER Wb2Root
    Path to the extracted WimBuilder2 tree (the folder holding WimBuilder.cmd).

.PARAMETER OutRoot
    Destination asset root, normally <repo>/src/uwp.

.PARAMETER Build
    Target Windows build number used to evaluate `+ver` guards. Default 26300.

.EXAMPLE
    .\tools\Import-Wb2UwpChain.ps1 -Wb2Root E:\wb2 -OutRoot .\src\uwp -Build 26300
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Wb2Root,

    [Parameter(Mandatory = $true)]
    [string] $OutRoot,

    [int] $Build = 26100,

    # Cumulative-update revision (VER[4]). wb2 gates files on the May 2025
    # (26100.4061) and August 2025 (26100.4946) update levels; the media this
    # project builds from is 26100.9457.
    [int] $Revision = 9457,

    # wb2 `opt[shell.app]`: the WinXShell slot was set to Explorer in this
    # project's profile. Guards in 00-Shell branch on it.
    [ValidateSet('explorer', 'winxshell')]
    [string] $ShellApp = 'explorer'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src/build/lib/Wb2List.ps1')

$projectRoot = Join-Path $Wb2Root 'Projects/WIN10XPE'
if (-not (Test-Path -LiteralPath $projectRoot)) {
    throw "Not a WimBuilder2 tree (missing Projects/WIN10XPE): $Wb2Root"
}

$filelistOut = Join-Path $OutRoot 'filelists'
$regOut = Join-Path $OutRoot 'reg/copy'
foreach ($dir in $filelistOut, $regOut) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$vars = Get-Wb2DefaultVars -Build $Build -Revision $Revision -ShellApp $ShellApp

# ---------------------------------------------------------------------------
# Which wb2 file feeds which MICPE asset
# ---------------------------------------------------------------------------

$jobs = @(
    @{ Out = '10-appx-runtime.txt';         Src = '01-Components/zp-UWPAppX/main.bat';             Marker = ':[AppX_Runtime]';              Title = 'AppX runtime - CLR / UCRT shims' }
    @{ Out = '11-appx-system.txt';          Src = '01-Components/zp-UWPAppX/main.bat';             Marker = ':[AppX_System]';               Title = 'AppX system layer - services, WinRT, input' }
    @{ Out = '20-appx-services.txt';        Src = '01-Components/zp-UWPAppX/AppSvrs/main.bat';     Marker = ':end_files';                   Title = 'AppX service hosts (AppXSvc deps, StateRepository)' }
    @{ Out = '30-appx-apps.txt';            Src = '01-Components/zp-UWPAppX/AppXapps/main.bat';    Marker = ':end_files';                   Title = 'UWP app runtime + ShellExperienceHost deps' }
    @{ Out = '31-appx-apps-extra.txt';      Src = '01-Components/zp-UWPAppX/AppXapps/main2.bat';   Marker = ':end_files';                   Title = 'UWP app runtime - second pass' }
    @{ Out = '40-appx-core.txt';            Src = '01-Components/zp-UWPAppX/main.bat';             Marker = ':[AppXCore_Files]';            Title = 'AppX core - deployment, VCLibs, AppRepository' }
    @{ Out = '41-appx-shellcomponents.txt'; Src = '01-Components/zp-UWPAppX/main.bat';             Marker = ':[AppXShellComponents_Files]'; Title = 'Shell components - taskbar, XAML shell, SystemResources' }
    @{ Out = '42-appx-taskmgr.txt';         Src = '01-Components/zp-UWPAppX/main.bat';             Marker = ':[AppXTaskmgr_Files]';         Title = 'UWP Task Manager + UI.Xaml.CBS' }
    @{ Out = '50-taskbar.txt';              Src = '01-Components/zp-UWPAppX/10-Taskbar/main.bat';  Marker = ':[Files]';                     Title = 'Native taskbar (UWP component)' }
    @{ Out = '51-startmenu.txt';            Src = '01-Components/zp-UWPAppX/11-StartMenu/main.bat'; Marker = ':[Files]';                    Title = 'UWP Start menu (OFF in the default profile)' }
    @{ Out = '52-settings.txt';             Src = '01-Components/zp-UWPAppX/12-Settings/main.bat'; Marker = ':[Files]';                     Title = 'UWP Settings app' }
    @{ Out = '60-shell-explorer.txt';       Src = '01-Components/00-Shell/main.bat';               Marker = ':end_files';                   Title = 'Explorer shell - common shell files' }
    @{ Out = '61-shell-explorer-app.txt';   Src = '01-Components/00-Shell/Explorer/submain.bat';   Marker = ':end_files';                   Title = 'Explorer shell - explorer.exe and its DLL set' }
    @{ Out = '70-dwm.txt';                  Src = '01-Components/DWM/main.bat';                    Marker = ':end_files';                   Title = 'Desktop Window Manager - dwm.exe and the DWM DLL set' }
)

function Write-Utf8NoBom {
    # The generated assets are consumed by PowerShell and by unit tests that
    # compare the first line; a BOM would break both.
    param([string] $Path, [System.Collections.Generic.List[string]] $Lines)

    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

function Find-AddFilesCall {
    param([string[]] $Lines, [string] $Marker)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -notmatch '^call\s+AddFiles\s+%0\s+') { continue }
        $call = [regex]::Match($Lines[$i], 'AddFiles\s+%0\s+(\S+)')
        if (-not $call.Success) { continue }
        if ($call.Groups[1].Value -eq $Marker) { return $i }
    }
    return -1
}

Write-Host "importing WimBuilder2 UWP chain (build $Build, shell $ShellApp)"
Write-Host "  source: $projectRoot"
Write-Host ''

foreach ($job in $jobs) {
    $srcPath = Join-Path $projectRoot $job.Src
    if (-not (Test-Path -LiteralPath $srcPath)) {
        Write-Warning "missing source, skipped: $($job.Src)"
        continue
    }

    $lines = @(Get-Content -LiteralPath $srcPath)
    $startIndex = Find-AddFilesCall -Lines $lines -Marker $job.Marker
    if ($startIndex -lt 0) {
        Write-Warning "no 'call AddFiles %0 $($job.Marker)' in $($job.Src), skipped"
        continue
    }

    $paths = @(Read-Wb2AddFilesBlock -Lines $lines -StartIndex $startIndex -Marker $job.Marker -Vars $vars -Build $Build)

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("# $($job.Title)")
    $out.Add('# Generated by tools/Import-Wb2UwpChain.ps1 -- do not hand-edit.')
    $out.Add("# Source: $($job.Src) $($job.Marker)")
    $out.Add('# Format: image-relative path with forward slashes. A trailing /')
    $out.Add('#         means "copy the whole directory tree".')
    $out.Add('#')
    foreach ($p in $paths) { $out.Add($p) }

    $path = Join-Path $filelistOut $job.Out
    Write-Utf8NoBom -Path $path -Lines $out
    Write-Host ("  {0,-34} {1,5} entries" -f $job.Out, $paths.Count)
}

# ---------------------------------------------------------------------------
# RegCopy / RegCopyEx extraction
# ---------------------------------------------------------------------------

$regSources = @(
    '01-Components/zp-UWPAppX/main.bat',
    '01-Components/zp-UWPAppX/AppSvrs/main.bat',
    '01-Components/zp-UWPAppX/AppXapps/main.bat',
    '01-Components/00-Shell/main.bat',
    '01-Components/00-Shell/Explorer/submain.bat',
    '01-Components/DWM/main.bat',
    'shared/StateRepositoryService/main.bat'
)

$services = [System.Collections.Generic.List[string]]::new()
$svcSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$keys = [System.Collections.Generic.List[string]]::new()
$keySeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$report = [System.Collections.Generic.List[string]]::new()

Write-Host ''
foreach ($rel in $regSources) {
    $srcPath = Join-Path $projectRoot $rel
    if (-not (Test-Path -LiteralPath $srcPath)) { continue }

    $n = 0
    foreach ($line in (Get-Content -LiteralPath $srcPath)) {
        $t = $line.Trim()
        if ($t -match '^(rem\b|;|::)') { continue }

        if ($t -match '^call\s+RegCopyEx\s+Services\s+"?([^"]+)"?\s*$') {
            foreach ($svc in ($Matches[1] -split ',')) {
                $name = $svc.Trim().Trim('"')
                if ($name -and $svcSeen.Add($name)) { $services.Add($name); $n++ }
            }
            continue
        }

        # call RegCopy <key>   (optionally with the /-s "no subkeys" switch)
        if ($t -match '^call\s+RegCopy\s+(/-s\s+)?([^\s"]+|"[^"]+")\s*$') {
            $key = $Matches[2].Trim('"')
            if ($key) {
                # wb2 writes a few keys as `HKLM\\SOFTWARE\...` or without the
                # `HKLM\` root at all; normalise so the build can split root/key.
                $key = $key -replace '\\\\', '\'
                if ($key -notmatch '^HK(LM|U|CR|CC)\b') { $key = 'HKLM\' + $key.TrimStart('\') }
                if ($keySeen.Add($key)) { $keys.Add($key); $n++ }
            }
            continue
        }
    }

    $report.Add("$rel -> $n registry entries")
    Write-Host ("  {0,-46} {1,3} registry entries" -f $rel, $n)
}

Write-Utf8NoBom -Path (Join-Path $regOut 'services.txt') -Lines $services
Write-Utf8NoBom -Path (Join-Path $regOut 'keys.txt') -Lines $keys
Write-Utf8NoBom -Path (Join-Path $regOut 'report.txt') -Lines $report

Write-Host ''
Write-Host ("services: {0}   keys: {1}" -f $services.Count, $keys.Count)
Write-Host "done -> $OutRoot"
