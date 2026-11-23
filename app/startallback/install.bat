@echo off
rem StartAllBack integration - runs in CI against a mounted boot.wim.
rem It never runs inside the PE: the image only carries the files this script
rem copied, plus the registrations in reg\ (imported by the build step).
rem
rem Called by the UWP chain as:
rem   install.bat <mounted boot.wim dir> <repo root> [build number]
rem
rem %1 = mounted image root (e.g. E:\micpe\mount)
rem %2 = repo root (unused here: the payload sits next to this script)
rem %3 = target Windows build number (e.g. 26300), optional. When given,
rem      the version gate (WimBuilder2 StartIsBack/main.bat:25-32) applies:
rem      build >= 26100 takes the vendor package from vendor\24H2\,
rem      older builds take vendor\ (root). When no vendor package exists
rem      (the 3.9.x package has not been delivered yet), the pre-extracted
rem      files\ copy is used instead, so the current product is unchanged.
rem
rem Target layout is StartAllBack's own: X:\Program Files\StartAllBack, because
rem the registrations hardcode that path and the binary looks for its Styles\
rem and Orbs\ next to itself. Do not move it into Program Files\MICPE.
rem
rem Idempotent: the destination is wiped first, so a rebuild never merges two
rem versions. Exit 0 on success, non-zero on the first failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
set "BUILD=%~3"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^> [build]& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2

set "DEST=%MOUNT%\Program Files\StartAllBack"
set "PKG="
rem Version gate (wb2 main.bat:25-32): build >= 26100 prefers vendor\24H2\,
rem otherwise vendor\ (root). VGetFile's rule: dir /b /on, take the last
rem name in sort order, so dropping a newer package into the folder makes
rem it the selected one with no script change. If the 24H2 folder is empty
rem the root folder is tried next (wb2's fallback); if both are empty the
rem pre-extracted files\ copy below is used.
if not "%BUILD%"=="" if %BUILD% geq 26100 (
    for /f %%F in ('dir /b /on "%~dp0vendor\24H2\StartAllBack_*_setup.exe" 2^>nul') do set "PKG=%~dp0vendor\24H2\%%F"
)
if not defined PKG (
    for /f %%F in ('dir /b /on "%~dp0vendor\StartAllBack_*_setup.exe" 2^>nul') do set "PKG=%~dp0vendor\%%F"
)
if defined PKG goto :SAB_VENDOR
rem No vendor package: fall back to the pre-extracted files\ (StartAllBack 3.6).
rem This is the current behaviour until the 3.9.x package is delivered.
echo StartAllBack: no vendor package, using pre-extracted files\ (3.6)
set "SRC=%~dp0files"
if not exist "%SRC%\StartAllBackX64.dll" echo StartAllBack payload missing: %SRC%\StartAllBackX64.dll& exit /b 2
if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"
xcopy "%SRC%\*" "%DEST%\" /e /h /i /q /y >nul
if errorlevel 1 echo copy to %DEST% failed& exit /b 1
goto :SAB_VERIFY

:SAB_VENDOR
rem WimBuilder2 Extract2X: the official .exe is a 7z self-extracting archive;
rem 7z x unpacks it, the installer never runs. Extract to a temp dir first so
rem a failed extraction never leaves a half-populated destination.
echo StartAllBack: extracting vendor package %PKG%
set "EXTRACT=%TEMP%\sab-extract-%RANDOM%"
if exist "%EXTRACT%" rmdir /s /q "%EXTRACT%"
mkdir "%EXTRACT%"
7z x -aoa "%PKG%" -o"%EXTRACT%" >nul
if errorlevel 1 echo StartAllBack vendor package failed to extract: %PKG%& rmdir /s /q "%EXTRACT%"& exit /b 1
if not exist "%EXTRACT%\StartAllBackX64.dll" echo StartAllBack vendor package has no StartAllBackX64.dll: %PKG%& rmdir /s /q "%EXTRACT%"& exit /b 1
rem Architecture cleanup (wb2 main.bat:35-48, x64 build): drop the ARM64 and
rem x86 variants, keep DarkMagicLoaderX64.exe, DarkMagicX64.dll and
rem UpdateCheck.exe.
del /q "%EXTRACT%\*A64.*" "%EXTRACT%\DarkMagic*X86.*" >nul 2>&1
if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"
xcopy "%EXTRACT%\*" "%DEST%\" /e /h /i /q /y >nul
if errorlevel 1 echo copy to %DEST% failed& rmdir /s /q "%EXTRACT%"& exit /b 1
rmdir /s /q "%EXTRACT%"

:SAB_VERIFY
if not exist "%DEST%\StartAllBackX64.dll" echo StartAllBack install incomplete: StartAllBackX64.dll missing& exit /b 1
if not exist "%DEST%\StartAllBackLoaderX64.dll" echo StartAllBack install incomplete: loader missing& exit /b 1
rem CurrentVersion in reg\default.reg must match the shipped DLL's major.minor
rem (a mismatch makes StartAllBack show its "settings were reset" dialog).
rem PowerShell is on every build host; a hand run without it skips the check.
where powershell >nul 2>&1
if errorlevel 1 (echo WARNING: powershell not found, skipping CurrentVersion check& goto :SAB_DONE)
powershell -NoProfile -Command "$dll=(Get-Item '%DEST%\StartAllBackX64.dll').VersionInfo.FileVersion; if ([string]::IsNullOrEmpty($dll)) { Write-Host 'WARNING: could not read SAB DLL version, skipping CurrentVersion check' } else { $mm=$dll.Split('.')[0]+'.'+$dll.Split('.')[1]; $q=[char]34; $reg=[IO.File]::ReadAllText('%~dp0reg\default.reg'); if ($reg.Contains($q+'CurrentVersion'+$q+'='+$q+$mm+$q)) { Write-Host ('SAB CurrentVersion ok: '+$mm) } else { Write-Host ('SAB CurrentVersion mismatch: DLL '+$dll+', expected '+$mm+' in default.reg'); exit 1 } }"
if errorlevel 1 exit /b 1

:SAB_DONE
echo StartAllBack installed to %DEST%
exit /b 0
