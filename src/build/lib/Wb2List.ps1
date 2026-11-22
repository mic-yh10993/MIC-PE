#Requires -Version 5.1
<#
.SYNOPSIS
    Reader for the WimBuilder2 file-list dialect.

.DESCRIPTION
    MICPE imports the UWP build chain from WimBuilder2 as declarative asset
    lists (src/uwp/filelists/*.txt). Two places need to understand those lists:

      * tools/Import-Wb2UwpChain.ps1  - turns a live wb2 tree into the lists
      * UwpChain.ps1                  - consumes the lists at build time

    Keeping the dialect in one module means the importer and the build can never
    disagree about what `@\Windows\System32\` or a trailing `\` means.

    Supported syntax (the subset the UWP chain actually uses):

        ; comment            rem comment            (also ::)
        @\Windows\System32\  switch the current base directory
        \Windows\x.dll       absolute (image-relative) entry
        foo.dll,bar.dll      comma-separated entries
        \Windows\Fonts\      trailing backslash = copy the whole tree
        %CatRoot%\x.cat      CatRoot macro
        +ver >= 22621        build guard (+ver* = always, +ver = always)
        +if "%X%"="1"        variable guard (also <> / != / > / < / Or chains)
        -if                  end of a guarded block

    Unrecognised guards evaluate to inactive: importing one optional file too
    few only costs a missing resource, while importing one too many can drag a
    whole unneeded subsystem into the image.
#>

Set-StrictMode -Version Latest

function Get-Wb2DefaultVars {
    <#
        .SYNOPSIS
            Variable table used to evaluate `+if` guards.

        .DESCRIPTION
            Values mirror the WimBuilder2 profile this project was built with:
            UWP default configuration, WinXShell shell slot set to Explorer, all
            UWP components on, Shell start menu off.
    #>
    [CmdletBinding()]
    param(
        # Windows build the source image is: WB_VER[3] / WB_VER[4] in wb2.
        # 26100.9457 is the 24H2 media this project builds from; the revision
        # matters because wb2 gates several files on the May/August 2025
        # cumulative update level (VER_202505_LATER / VER_202508_LATER).
        [int] $Build = 26100,

        [int] $Revision = 9457,

        # wb2 `opt[shell.app]`: 'explorer' or 'winxshell'. The 00-Shell guards
        # branch on this value, so it must match the profile.
        [ValidateSet('explorer', 'winxshell')]
        [string] $ShellApp = 'explorer'
    )

    # wb2 Projects/WIN10XPE/main.bat, same thresholds (26100.4061 = May 2025,
    # 26100.4946 = August 2025 update).
    $may2025 = 0
    $aug2025 = 0
    if ($Build -ge 22631) {
        if ($Revision -ge 5335) { $may2025 = 1 }
        if ($Revision -ge 5768) { $aug2025 = 1 }
    }
    if ($Build -ge 26100) {
        if ($Revision -ge 4061) { $may2025 = 1 }
        if ($Revision -gt 4946) { $aug2025 = 1 }
    }
    if ($Build -ge 27842) { $may2025 = 1 }
    if ($Build -ge 27909) { $aug2025 = 1 }

    return @{
        'VER[3]'                    = "$Build"
        'VER[4]'                    = "$Revision"
        'VER_202505_LATER'          = "$may2025"
        'VER_202508_LATER'          = "$aug2025"
        'opt[shell.app]'            = $ShellApp
        'opt[build.registry.software]' = 'default'

        # wb2 builds from one of winre.wim / boot.wim / install.wim; the DWM
        # component adds d2d1/d3d10warp only for the latter two. This project
        # builds from the installer's boot.wim, so the guard takes that branch.
        'opt[build.wim]'            = 'boot'
    }
}

function Test-Wb2GuardLine {
    <#
        .SYNOPSIS
            Evaluates one `+ver` / `+if` guard line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Line,

        [Parameter(Mandatory = $true)]
        [hashtable] $Vars,

        [int] $Build = 26300
    )

    $t = $Line.Trim()

    if ($t -match '^\+ver\*?$') { return $true }

    if ($t -match '^\+ver\s*(>=|<=|>|<)\s*(\d+)$') {
        $op = $Matches[1]
        $value = [int] $Matches[2]
        switch ($op) {
            '>=' { return ($Build -ge $value) }
            '<=' { return ($Build -le $value) }
            '>' { return ($Build -gt $value) }
            '<' { return ($Build -lt $value) }
        }
    }

    if ($t -match '^\+if\s+(.+)$') {
        $expr = $Matches[1]
        foreach ($clause in ($expr -split '\s+Or\s+')) {
            # wb2 writes guards in three shapes, all of which have to parse:
            #   "%VER[3]%" = "19041"        quoting around the variable only
            #   "x%VER_202505_LATER%"="x1"  quoting around the x-prefixed value
            #   %opt[shell.app]%==explorer  no quotes at all
            # The old pattern required the variable to be followed directly by
            # the operator, so "x%VER_202505_LATER%"="x1" never matched: the
            # guard silently evaluated false and dropped mdmregistration.dll and
            # SystemSettings.DataModel.dll from the Explorer list. explorer.exe
            # imports MDMRegistration.dll statically, so the shell could not
            # start at all (v2 boot: three attempts, no process, no message).
            $m = [regex]::Match(
                $clause,
                '"?\s*x?%([A-Za-z0-9_.\[\]]+)%"?\s*(<>|!=|>=|<=|==|=|>|<)\s*"?\s*x?([^"]*)"?')
            if (-not $m.Success) {
                throw [System.InvalidOperationException]::new(
                    "cannot parse wb2 guard clause '$clause' (from '$t'); refusing to guess its result")
            }
            $name = $m.Groups[1].Value
            $op = $m.Groups[2].Value
            $want = $m.Groups[3].Value.Trim()
            if (-not $Vars.ContainsKey($name)) {
                # Defaulting an unknown variable to '' is what let a whole
                # version-gated block disappear without a word. Fail instead.
                throw [System.InvalidOperationException]::new(
                    "wb2 guard uses variable '$name' which is not in the variable table; add it to Get-Wb2DefaultVars before importing")
            }
            $have = [string] $Vars[$name]

            # wb2 writes "x%VAR%" so that an unset variable compares as "x"
            # rather than as an empty string; the x is stripped from both sides.
            switch ($op) {
                '=' { if ($have -eq $want) { return $true } }
                '==' { if ($have -eq $want) { return $true } }
                '<>' { if ($have -ne $want) { return $true } }
                '!=' { if ($have -ne $want) { return $true } }
                '>=' { if ([int]$have -ge [int]$want) { return $true } }
                '<=' { if ([int]$have -le [int]$want) { return $true } }
                '>' { if ([int]$have -gt [int]$want) { return $true } }
                '<' { if ([int]$have -lt [int]$want) { return $true } }
            }
        }
        return $false
    }

    return $true
}

function ConvertTo-Wb2ListPath {
    <#
        .SYNOPSIS
            Expands one list entry against the current `@base` into an
            image-relative path with forward slashes.

        .DESCRIPTION
            Returns $null for entries that do not describe an image file
            (environment paths, drive letters). A trailing slash is preserved to
            mean "copy the whole tree".
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Base,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Entry
    )

    $name = $Entry.Trim()
    if (-not $name) { return $null }
    if ($name -match '^(rem\b|;|::)') { return $null }

    # %CatRoot% is the only macro the UWP chain uses.
    if ($name -match '^%CatRoot%[\\/](.*)$') {
        $rest = $Matches[1] -replace '\\', '/'
        return "Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/$rest"
    }

    # Drive letters and other environment paths belong to the running PE.
    if ($name -match '^[A-Za-z]:' -or $name -match '^%[A-Za-z]+%') { return $null }

    $trailing = if ($name.EndsWith('\') -or $name.EndsWith('/')) { '/' } else { '' }

    if ($name.StartsWith('\')) {
        $path = $name.TrimStart('\')
    }
    elseif ($Base) {
        $path = $Base.TrimStart('\').TrimEnd('\') + '/' + $name
    }
    else {
        $path = $name
    }

    $path = ($path -replace '\\', '/')
    $path = $path.TrimStart('/').TrimEnd('/')
    if (-not $path) { return $null }
    return $path + $trailing
}

function Read-Wb2AddFilesBlock {
    <#
        .SYNOPSIS
            Reads one `call AddFiles %0 <marker>` block.

        .DESCRIPTION
            Works in two phases on purpose: first collect the raw lines of the
            block (so the marker logic is easy to reason about), then expand them
            with the guard state machine. `:[Section]` markers jump to the label
            further down the file; `:end_files` blocks start right after the
            `call` line, past the framing `goto :end_files`.

        .PARAMETER Lines
            The .bat file contents.

        .PARAMETER StartIndex
            0-based index of the `call AddFiles` line.

        .PARAMETER Marker
            The marker as written on the call line, e.g. `:[AppX_System]`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]] $Lines,

        [Parameter(Mandatory = $true)]
        [int] $StartIndex,

        [Parameter(Mandatory = $true)]
        [string] $Marker,

        [hashtable] $Vars,

        [int] $Build = 26300
    )

    if (-not $Vars) { $Vars = Get-Wb2DefaultVars -Build $Build }

    $start = $StartIndex + 1
    if ($Marker -ne ':end_files') {
        $found = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i].Trim() -eq $Marker) { $found = $i; break }
        }
        if ($found -lt 0) {
            throw "AddFiles marker '$Marker' not found (call at line $($StartIndex + 1))"
        }
        $start = $found + 1
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $base = $null
    # wb2 has TWO independent guard kinds:
    #   +ver >= N ... +ver*      version window; each new +ver line replaces the
    #                            current window, no -if terminator
    #   +if "..." ... -if        stack of boolean blocks
    # Effective activity is their conjunction, which is why they are tracked
    # separately instead of on one stack.
    $verActive = $true
    $ifActive = $true
    $ifStack = [System.Collections.Generic.Stack[bool]]::new()

    for ($i = $start; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i].Trim()
        Write-Verbose ("[{0}] {1}" -f $i, $line)

        if ($line -eq ':end_files') { break }
        if ($line -match '^:[A-Za-z_\[].*') { break }        # next label ends the block
        if (-not $line) { continue }
        if ($line -match '^(rem\b|;|::)') { continue }
        if ($line -match '^goto\s+:(.+)$') {
            $target = ':' + $Matches[1].Trim()
            if ($target -eq ':end_files' -or $target -eq $Marker) { continue }
            break
        }

        if ($line -eq '-if') {
            if ($ifStack.Count -gt 0) { $ifActive = $ifStack.Pop() }
            continue
        }
        if ($line.StartsWith('+')) {
            if ($line -match '^\+ver') {
                $verActive = Test-Wb2GuardLine -Line $line -Vars $Vars -Build $Build
            }
            elseif ($line -match '^\+if') {
                $ifStack.Push($ifActive)
                $guard = Test-Wb2GuardLine -Line $line -Vars $Vars -Build $Build
                $ifActive = $ifActive -and $guard
            }
            continue
        }

        if (-not ($verActive -and $ifActive)) { continue }

        if ($line.StartsWith('@')) {
            $base = $line.Substring(1).Trim()
            continue
        }

        foreach ($piece in ($line -split ',')) {
            $path = ConvertTo-Wb2ListPath -Base $base -Entry $piece
            if (-not $path) { continue }
            if ($seen.Add($path)) { $paths.Add($path) }
        }
    }

    return $paths.ToArray()
}
