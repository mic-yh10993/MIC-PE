@echo off
rem ---------------------------------------------------------------------------
rem MICPE in-PE self check.
rem
rem Runs inside the booted PE. Writes key=value lines to a file on the vvfat
rem share drive so the CI host can read them without OCR or serial capture.
rem
rem This file is invoked by PECMD.INI after the shell is up. Keeping it as a
rem batch script means it works even when PowerShell has not been provisioned
rem yet, which matters for the early stages.
rem ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion

rem Scan every drive except the PE system drive X: for a writable
rem directory to put the probe file on. The CI harness attaches the
rem vvfat share as the first IDE hard disk, which WinPE letters C:;
rem the boot ISO (optical) is D: and read-only, so C: must be in the
rem list or the scan finds nothing writable (run 44101018512).
rem A/B are floppy letters and stay out.
set "PROBE_DIR="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\" (
        rem 2>nul must come BEFORE the output redirect: cmd reports a
        failed open to the stderr that is current at that point, so
        "> file 2>nul" still prints "Access is denied" on a read-only
        drive (run 25 screenshot) while "2>nul > file" stays silent.
        rem A failed write just skips this drive; the loop moves on.
        echo test 2>nul > "%%D:\micpe-write-test.tmp"
        if exist "%%D:\micpe-write-test.tmp" (
            del "%%D:\micpe-write-test.tmp" >nul 2>&1
            if not defined PROBE_DIR set "PROBE_DIR=%%D:\"
        )
    )
)

if not defined PROBE_DIR (
    set "PROBE_OUT=X:\micpe-probe.txt"
    set "SHARE=0"
) else (
    set "PROBE_OUT=%PROBE_DIR%micpe-probe.txt"
    set "SHARE=1"
)

> "%PROBE_OUT%" echo boot=1
>> "%PROBE_OUT%" echo share=%SHARE%
if defined PROBE_DIR >> "%PROBE_OUT%" echo share_drive=%PROBE_DIR%

rem --- shell -----------------------------------------------------------------
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer=0 >> "%PROBE_OUT%") else (echo explorer=1 >> "%PROBE_OUT%")

tasklist /fi "imagename eq dwm.exe" /nh 2>nul | find /i "dwm.exe" >nul
if errorlevel 1 (echo dwm=0 >> "%PROBE_OUT%") else (echo dwm=1 >> "%PROBE_OUT%")

rem The shell is considered ready only after it has survived a settle period;
rem a crash-on-start explorer still appears in tasklist for a second or two.
ping -n 16 127.0.0.1 >nul 2>&1
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo shell_ready=0 >> "%PROBE_OUT%") else (echo shell_ready=1 >> "%PROBE_OUT%")

rem --- network ---------------------------------------------------------------
set "IPV4="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /c:"IPv4"') do (
    if not defined IPV4 set "IPV4=%%A"
)
if defined IPV4 (echo network=!IPV4: =! >> "%PROBE_OUT%") else (echo network=pending >> "%PROBE_OUT%")

rem --- input method ----------------------------------------------------------
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload" 2>nul | find /i "0804" >nul
if errorlevel 1 (echo ime=0 >> "%PROBE_OUT%") else (echo ime=1 >> "%PROBE_OUT%")

rem --- uwp -------------------------------------------------------------------
if exist "%SystemRoot%\System32\AppXDeploymentClient.dll" (
    echo uwp_appx=1 >> "%PROBE_OUT%"
) else (
    echo uwp_appx=0 >> "%PROBE_OUT%"
)

rem Keys are spelled out rather than built from a suffix so the CI-side
rem assertion table can be grepped against this file literally.
rem No Settings probe: the Settings app is not provisioned (user decision
rem 2026-11-16, too heavy). Calculator takes its place as the third app.
rem NOTE (unverified against a real system): the Calculator process image
rem is CalculatorApp.exe; if the L3 run shows uwp_launch_calculator=0
rem while the app itself launches, correct the process name here.
call :probe_uwp CalculatorApp "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_calculator=0 >> "%PROBE_OUT%") else (echo uwp_launch_calculator=1 >> "%PROBE_OUT%")

call :probe_uwp Microsoft.Photos "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_photos=0 >> "%PROBE_OUT%") else (echo uwp_launch_photos=1 >> "%PROBE_OUT%")

call :probe_uwp Microsoft.ZuneMusic "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
if errorlevel 1 (echo uwp_launch_media=0 >> "%PROBE_OUT%") else (echo uwp_launch_media=1 >> "%PROBE_OUT%")

rem --- payload ---------------------------------------------------------------
set "PAYLOAD=1"
for %%F in (
    "X:\Program Files\MICPE\PENetwork\PENetwork.exe"
    "X:\Program Files\7-zip\7z.exe"
    "X:\Program Files\DiskGenius.exe"
    "X:\Program Files\WinNTSetup\unattend\Win10_x64.xml"
) do (
    if not exist %%F set "PAYLOAD=0"
)
echo payload=%PAYLOAD% >> "%PROBE_OUT%"

rem --- brand ----------------------------------------------------------------
set "BRAND=1"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Manufacturer 2>nul | find /i "MICPE" >nul
if errorlevel 1 set "BRAND=0"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v SupportURL 2>nul | find /i "space.bilibili.com/1978487514" >nul
if errorlevel 1 set "BRAND=0"
if not exist "%SystemRoot%\System32\oemlogo.bmp" set "BRAND=0"
echo brand=%BRAND% >> "%PROBE_OUT%"

rem --- installer -------------------------------------------------------------
rem M6: run the installer in -cli -discoveronly mode so it writes
rem installer_scan / installer_source / installer_name / installer_path
rem into the same probe file (design §6). M7: when a source was found and
rem data disks are attached (plan Task 17 Step 6), the deploy step below
rem calls -cli -deploy, which writes installer_deploy after a successful
rem apply + boot repair.
rem The .wcs path is checked first so a missing installer fails loudly
rem (installer_scan=0) instead of silently leaving the key out.
set "MICPE_PROBE_FILE=%PROBE_OUT%"
if exist "%SystemDrive%\Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs" (
    pecmd.exe "%SystemDrive%\Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs" -cli -discoveronly
) else (
    echo installer_scan=0 >> "%PROBE_OUT%"
)

rem --- installer deploy (M7 harness, plan Task 17 Step 6) --------------------
rem When the scan found a source, deploy it to the largest free volume that
rem is neither the source volume, the PE volume nor the probe share (in the
rem CI harness that is the blank 64 GB disk). Without data disks there is
rem no safe target: the scan only ever sees the boot ISO itself, so the
rem target pick comes back empty and this step is skipped.
rem installer_deploy=1 is written by the .wcs itself after a successful
rem apply + boot repair; installer_boot=1 means bcdboot left a BCD store
rem on the target.
set "DEPLOY_SRC="
for /f "tokens=1,* delims==" %%A in ('findstr /b "installer_path=" "%PROBE_OUT%" 2^>nul') do set "DEPLOY_SRC=%%B"
if not defined DEPLOY_SRC goto :skip_deploy
set "DEPLOY_TARGET="
for /f "usebackq delims=" %%T in (`powershell.exe -NoProfile -Command "Get-PSDrive -PSProvider FileSystem ^| Where-Object { $_.Free -gt 0 -and $_.Root -ne '%PROBE_DIR%' -and $_.Root -ne 'X:\' -and $_.Root.Substring(0,1) -ne '%DEPLOY_SRC:~0,1%' } ^| Sort-Object Free -Descending ^| Select-Object -First 1 -ExpandProperty Name"`) do set "DEPLOY_TARGET=%%T"
if not defined DEPLOY_TARGET goto :skip_deploy
pecmd.exe "%SystemDrive%\Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs" -cli -deploy "%DEPLOY_SRC%" %DEPLOY_TARGET%
if exist "%DEPLOY_TARGET%:\EFI\Microsoft\Boot\BCD" echo installer_boot=1 >> "%PROBE_OUT%"
:skip_deploy

echo probe_done=1 >> "%PROBE_OUT%"

if "%MICPE_HOLD%"=="1" (
    echo.
    echo MICPE probe written to %PROBE_OUT%
    echo Press any key to shut down.
    pause >nul
)

shutdown /s /t 5 /f >nul 2>&1
endlocal
exit /b 0

:probe_uwp
rem %1 = process image name, %2 = shell target
rem Returns errorlevel 0 when the process is running after the launch attempt.
set "UWP_PROC=%~1"
set "UWP_TARGET=%~2"

tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul
if not errorlevel 1 (
    rem Already running, relaunching would be a no-op.
    exit /b 0
)

start "" explorer.exe "%UWP_TARGET%"
ping -n 8 127.0.0.1 >nul 2>&1
tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul
exit /b %errorlevel%
