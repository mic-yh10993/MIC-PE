#Requires -Version 7.0
<#
.SYNOPSIS
    UWP stack assembly: AppX framework packages, provisioned apps, checks.

.DESCRIPTION
    WinPE on its own cannot run UWP apps. The AppX stack comes from
    install.wim in three parts:

    1. The framework packages under Program Files\WindowsApps
       (VCLibs 140, .NET Native, WinUI XAML, Windows App Runtime).
    2. The app packages themselves (Photos, Media Player, Calculator).
    3. The System32 deployment client/server DLLs (50-uwp.txt) plus the
       registry policy in 40-uwp.reg.

    Registration writes only the AppxAllUserStore allow-run keys and the
    InboxApplications Path values. The StateRepository database itself is
    never copied: it must be generated on first boot, and copying one
    fails activation with 0x80073CF9.

    Scope note (user decision 2026-11-16): UWP keeps core files only. The
    Settings app is too heavy and is NOT provisioned, and the Store is not
    a core offline capability for a repair disk, so Get-UwpDefaults
    returns Photos, Media Player and Calculator only. There is deliberately
    no self-implemented settings tool in this round: no list of which
    settings it must cover has been specified yet.
#>

function Get-UwpDefaults {
    [CmdletBinding()]
    param()

    # User decision 2026-11-16: core files only. Settings is too heavy to
    # ship; the Store is not an offline repair-disk capability. Keep this
    # list in sync with tests/Uwp.Tests.ps1, which pins both exclusions.
    return @('Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.ZuneMusic')
}

function Get-UwpFrameworkPatterns {
    [CmdletBinding()]
    param()

    # // reuse-check: prefix set is plan T12 verbatim (VCLibs 140 /
    # .NET Native / WinUI XAML / Windows App Runtime). Pure function so
    # the selection is unit-testable without a real install.wim.
    return @(
        'Program Files\WindowsApps\Microsoft.VCLibs.140.00*'
        'Program Files\WindowsApps\Microsoft.NET.Native.*'
        'Program Files\WindowsApps\Microsoft.UI.Xaml.*'
        'Program Files\WindowsApps\Microsoft.WindowsAppRuntime*'
    )
}

function Install-AppxFramework {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $InstallWim,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [string] $WimlibPath = 'wimlib-imagex',

        [int] $InstallIndex = 1
    )

    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    Assert-PathExists -Path $InstallWim -Label 'install.wim'

    Write-Step 'extracting the UWP stack files'
    $stackPatterns = Read-Whitelist -Path (Join-Path $RepoRoot 'src/filelists/50-uwp.txt')
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $stackPatterns -WimlibPath $WimlibPath

    Write-Step 'extracting the AppX framework packages'
    $frameworkPatterns = Get-UwpFrameworkPatterns
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $frameworkPatterns -WimlibPath $WimlibPath

    # NOTE (unverified against a real install.wim): the framework patterns
    # rely on wimlib-imagex extracting a wildcard-matched directory
    # recursively. If the L2 structural check shows 25H2 lays the
    # WindowsApps tree out differently, adjust the patterns here; do not
    # weaken the count assertion below.
    $windowsApps = Join-Path $MountDir 'Program Files\WindowsApps'
    $frameworkDirs = @()
    if (Test-Path -LiteralPath $windowsApps) {
        $leaves = @(Get-UwpFrameworkPatterns | ForEach-Object { ($_ -split '\\')[-1] })
        $frameworkDirs = @(Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $candidate = $_.Name
                @($leaves | Where-Object { $candidate -like $_ }).Count -gt 0
            })
    }
    if ($frameworkDirs.Count -lt 5) {
        throw [System.InvalidOperationException]::new(
            "AppX framework is incomplete: found $($frameworkDirs.Count) framework package directories, need at least 5")
    }

    $missing = @()
    foreach ($dll in 'Windows\System32\AppXDeploymentClient.dll', 'Windows\System32\Windows.UI.Xaml.dll') {
        if (-not (Test-Path -LiteralPath (Join-Path $MountDir $dll))) { $missing += $dll }
    }
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "UWP stack is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep ("AppX framework verified ({0} package directories)" -f $frameworkDirs.Count)
}

function Install-UwpApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [Parameter(Mandatory = $true)]
        [string] $InstallWim,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [AllowEmptyCollection()]
        [string[]] $PackageNames = (Get-UwpDefaults),

        [string] $WimlibPath = 'wimlib-imagex',

        [int] $InstallIndex = 1
    )

    Assert-PathExists -Path $MountDir -Label 'boot.wim mount'
    Assert-PathExists -Path $InstallWim -Label 'install.wim'

    # A mandatory PackageNames would prompt on stdin when a caller omits
    # it, and an unattended run then hangs forever instead of failing.
    # Default to the provisioned set; an explicitly empty list is a
    # caller error, not a vacuous success.
    if ($PackageNames.Count -eq 0) {
        throw [System.InvalidOperationException]::new('no UWP app package names supplied')
    }

    # Plan T12 extracts only the framework families and never the app
    # packages themselves, yet Assert-UwpReady requires one
    # WindowsApps\<name>_* directory per default app. Extract the apps
    # here so the assertion has something to check.
    Write-Step 'extracting the provisioned UWP apps'
    $patterns = @($PackageNames | ForEach-Object { "Program Files\WindowsApps\${_}*" })
    Export-WimFiles -WimPath $InstallWim -Index $InstallIndex `
        -Destination $MountDir -Patterns $patterns -WimlibPath $WimlibPath

    $windowsApps = Join-Path $MountDir 'Program Files\WindowsApps'
    $missing = @()
    foreach ($name in $PackageNames) {
        $dirs = @()
        if (Test-Path -LiteralPath $windowsApps) {
            $dirs = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "$name*" -ErrorAction SilentlyContinue)
        }
        if ($dirs.Count -eq 0) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "UWP app packages are incomplete. Missing WindowsApps directories for:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'provisioned UWP app packages verified'
}

function New-UwpProvisionRegContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Resolved,

        [Parameter(Mandatory = $true)]
        [string] $HiveKey
    )

    # Pure function so the generated file is unit-testable without reg.exe.
    # Lines are joined with CRLF explicitly: reg.exe rejects LF-only .reg
    # files, and a Linux PowerShell would otherwise write bare LF (CI run
    # 44007177632 proved the import fails with exit code 1 on exactly that).
    # Backslashes in the Path values are doubled, which is the .reg escape
    # for a literal backslash; reg import stores a single one.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Windows Registry Editor Version 5.00')
    $lines.Add('')
    foreach ($name in @($Resolved.Keys | Sort-Object)) {
        $full = $Resolved[$name]
        $path = "X:\\Program Files\\WindowsApps\\$full"
        $lines.Add("[HKEY_LOCAL_MACHINE\$HiveKey\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications\$full]")
        $lines.Add("`"Path`"=`"$path`"")
        $lines.Add('')
        $lines.Add("[HKEY_LOCAL_MACHINE\$HiveKey\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\$name]")
        $lines.Add("`"Path`"=`"$path`"")
        $lines.Add('')
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Register-ProvisionedAppx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir,

        [AllowEmptyCollection()]
        [string[]] $PackageNames = (Get-UwpDefaults),

        [string] $HiveKey = 'PE-UWP'
    )

    $hiveFile = Join-Path $MountDir 'Windows/System32/config/SOFTWARE'
    Assert-PathExists -Path $hiveFile -Label 'SOFTWARE hive'

    # Same no-prompt rule as Install-UwpApps: never let a missing
    # argument turn an unattended run into a stdin prompt.
    if ($PackageNames.Count -eq 0) {
        throw [System.InvalidOperationException]::new('no UWP app package names supplied')
    }

    $windowsApps = Join-Path $MountDir 'Program Files\WindowsApps'

    # Resolve the versioned directory for each family before touching the
    # hive, so a missing package fails fast with its own name.
    $resolved = @{}
    foreach ($name in $PackageNames) {
        $dirs = @()
        if (Test-Path -LiteralPath $windowsApps) {
            $dirs = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "$name*" -ErrorAction SilentlyContinue)
        }
        if ($dirs.Count -eq 0) {
            throw [System.InvalidOperationException]::new(
                "cannot register $name : no 'Program Files\WindowsApps\$name*' directory under the mount")
        }
        # install.wim carries one version per family; take the first in
        # sorted order so the choice is deterministic.
        $resolved[$name] = ($dirs | Sort-Object Name | Select-Object -First 1).Name
    }

    # The hive is written through a generated .reg imported with reg.exe,
    # never through the PowerShell registry provider: the provider keeps
    # an open handle on the key, and a later `reg unload` then fails with
    # exit code 1 (CI run 44001157082 proved it). Paths are X: because
    # that is the PE system drive at runtime. The file is written with
    # WriteAllText + Encoding.Unicode (UTF-16LE with BOM) so the bytes are
    # identical on Linux and Windows hosts.
    $content = New-UwpProvisionRegContent -Resolved $resolved -HiveKey $HiveKey
    $regPath = Join-Path ([System.IO.Path]::GetTempPath()) "micpe-uwp-$(Get-Random).reg"
    [System.IO.File]::WriteAllText($regPath, $content, [System.Text.Encoding]::Unicode)
    try {
        Mount-RegistryHive -HiveFile $hiveFile -KeyName $HiveKey
        try {
            Import-RegFile -RegFile $regPath
            foreach ($name in $PackageNames) {
                $values = Get-RegistryKeyValues -KeyName $HiveKey `
                    -SubKey "Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\$name"
                if ($null -eq $values) {
                    throw [System.InvalidOperationException]::new(
                        "provisioned AppX registration is missing: InboxApplications\$name")
                }
            }
            Write-SubStep 'provisioned UWP apps registered'
        }
        finally {
            # A failing unload must not mask the real assertion above: warn
            # and continue, matching Invoke-RegistryScript's finally
            # convention.
            try {
                Dismount-RegistryHive -KeyName $HiveKey
            }
            catch {
                Write-Warn "could not unload HKLM\$HiveKey : $($_.Exception.Message)"
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $regPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-UwpReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $MountDir
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    $system32 = Join-Path $MountDir 'Windows/System32'
    foreach ($dll in 'AppXDeploymentClient.dll', 'Windows.UI.Xaml.dll') {
        if (-not (Test-Path -LiteralPath (Join-Path $system32 $dll))) {
            $missing.Add("System32/$dll")
        }
    }

    $stateRepo = @()
    if (Test-Path -LiteralPath $system32) {
        $stateRepo = @(Get-ChildItem -LiteralPath $system32 -Filter 'Windows.StateRepository*' -File -ErrorAction SilentlyContinue)
    }
    if ($stateRepo.Count -lt 4) {
        $missing.Add("Windows.StateRepository* family (found $($stateRepo.Count), need at least 4)")
    }

    if (-not (Test-Path -LiteralPath (Join-Path $MountDir 'ProgramData/Microsoft/Windows/AppRepository'))) {
        $missing.Add('ProgramData/Microsoft/Windows/AppRepository directory')
    }

    $windowsApps = Join-Path $MountDir 'Program Files\WindowsApps'
    foreach ($name in Get-UwpDefaults) {
        $dirs = @()
        if (Test-Path -LiteralPath $windowsApps) {
            $dirs = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "$name*" -ErrorAction SilentlyContinue)
        }
        if ($dirs.Count -eq 0) {
            $missing.Add("WindowsApps\${name}_* package directory")
        }
    }

    if ($missing.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "UWP stack is incomplete. Missing:`n  " + ($missing -join "`n  "))
    }

    Write-SubStep 'UWP stack artifacts verified'
}
