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
rem The write test is "echo test 2>nul > file". NOTE (corrected by the
rem run 44135105700 mechanism experiment, Test run 44154459167): a failed
rem output open prints "Access is denied" whether 2>nul comes first or
rem last, so the order silences nothing; the line is cosmetic noise on
rem the read-only boot ISO. A failed write just skips the drive; the
rem loop moves on (the file-existence check below is what skips it).
set "PROBE_DIR="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\" (
        rem The order is kept as-is; it does not silence the error, see the note above.
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

rem Watchdog (run 44285721257): if this probe stalls or dies mid-run, no
rem probe_done line is ever written and the CI host waits out the full
rem 45 minutes. A detached watcher notices the probe file going quiet
rem and records probe_failed=1, which ends the wait early without
rem changing the verdict: probe_failed still fails the run, see
rem Assert-Probe. The watcher only runs when its own script made it
rem into the image; a missing file is a silent no-op.
if exist "%SystemRoot%\System32\probe-watchdog.cmd" start "" /min cmd /c %SystemRoot%\System32\probe-watchdog.cmd "%PROBE_OUT%"

rem --- pecmd markers ---------------------------------------------------------
rem Diagnostic, run 44267918861: PECMD.INI and startnet.cmd write
rem mark_pecmd_* and mark_startnet_* lines to
rem %SystemDrive%\micpe-pecmd-marks.txt. Copy them into the probe file so the
rem CI harness can see how far the PECMD chain got, even when this probe run
rem is the startnet control call. mark_ keys are parsed but never asserted,
rem see Assert-Probe. The type-in sits this early so the marks survive even
rem if the probe dies in a later section.
if exist "%SystemDrive%\micpe-pecmd-marks.txt" (
    type "%SystemDrive%\micpe-pecmd-marks.txt" >> "%PROBE_OUT%"
)

rem --- drive letters ---------------------------------------------------------
rem Fix-DriveLetters.cmd (startnet.cmd, user decision 2026-11-17 23:43) wrote
rem pe_drive / win_drive / drive_fixed (and drive_fix_error on failure) to
rem %SystemDrive%\micpe-drive-letters.txt. Copy the lines verbatim so
rem Assert-Probe can check them. If the file is missing the image predates
rem the fix and the keys stay missing (fail loudly, not silently).
if exist "%SystemDrive%\micpe-drive-letters.txt" (
    type "%SystemDrive%\micpe-drive-letters.txt" >> "%PROBE_OUT%"
) else (
    echo drive_letters=missing >> "%PROBE_OUT%"
)

rem --- shell -----------------------------------------------------------------
rem Progress marker: the section start time, so a partial probe still shows
rem where it stopped and how long each section took (run 44181949882: run 29
rem stopped after dwm=1 and the evidence could not tell "died" from "slow").
rem mark_<section> keys are parsed by Read-ProbeFile and shown in the CI log
rem printout, but no stage table asserts them, so they cannot mask a failure.
rem %TIME: =0% zero-pads the hour; the line is top-level, not inside a (...)
rem block, so %TIME% is read when the line runs instead of at block parse.
echo mark_shell_ready=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer=0 >> "%PROBE_OUT%") else (echo explorer=1 >> "%PROBE_OUT%")

tasklist /fi "imagename eq dwm.exe" /nh 2>nul | find /i "dwm.exe" >nul
if errorlevel 1 (echo dwm=0 >> "%PROBE_OUT%") else (echo dwm=1 >> "%PROBE_OUT%")

rem The shell is considered ready only after it has survived a settle period;
rem a crash-on-start explorer still appears in tasklist for a second or two.
rem Settle markers (run 44249181100): runs 31/32 stopped between
rem mark_shell_ready and shell_ready, and the gap holds only the ping below
rem and one more tasklist call. These three markers say which of the two it
rem was; they are mark_ keys, parsed but never asserted (see Assert-Probe).
echo mark_shell_ping_before=%TIME: =0% >> "%PROBE_OUT%"
ping -n 16 127.0.0.1 >nul 2>&1
echo mark_shell_ping_after=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
echo mark_shell_check_after=%TIME: =0% >> "%PROBE_OUT%"
if errorlevel 1 (echo shell_ready=0 >> "%PROBE_OUT%") else (echo shell_ready=1 >> "%PROBE_OUT%")

rem --- network ---------------------------------------------------------------
echo mark_network=%TIME: =0% >> "%PROBE_OUT%"
set "IPV4="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /c:"IPv4"') do (
    if not defined IPV4 set "IPV4=%%A"
)
if defined IPV4 (echo network=!IPV4: =! >> "%PROBE_OUT%") else (echo network=pending >> "%PROBE_OUT%")

rem --- input method ----------------------------------------------------------
echo mark_ime=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload" 2>nul | find /i "0804" >nul
if errorlevel 1 (echo ime=0 >> "%PROBE_OUT%") else (echo ime=1 >> "%PROBE_OUT%")

rem --- uwp -------------------------------------------------------------------
echo mark_uwp_appx=%TIME: =0% >> "%PROBE_OUT%"
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
rem Launching a UWP app needs a running Explorer shell. At m4 there is
rem no shell, so the launch is skipped and 0 is recorded, meaning not
rem launchable here; m7 verifies the launch with the full image.
rem Delayed expansion strips the bang from the AppUserModelId, Test run
rem 44178703900 U3: the Calculator target arrived with the bang dropped,
rem so the launch could never resolve. It is switched off around the
rem three calls below; nothing in this section needs delayed expansion.
setlocal DisableDelayedExpansion
echo mark_uwp_launch_calculator=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp CalculatorApp "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_calculator=0 >> "%PROBE_OUT%") else (echo uwp_launch_calculator=1 >> "%PROBE_OUT%")

echo mark_uwp_launch_photos=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp Microsoft.Photos "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_photos=0 >> "%PROBE_OUT%") else (echo uwp_launch_photos=1 >> "%PROBE_OUT%")

echo mark_uwp_launch_media=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp Microsoft.ZuneMusic "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
if errorlevel 1 (echo uwp_launch_media=0 >> "%PROBE_OUT%") else (echo uwp_launch_media=1 >> "%PROBE_OUT%")
endlocal

rem --- payload ---------------------------------------------------------------
echo mark_payload=%TIME: =0% >> "%PROBE_OUT%"
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
echo mark_brand=%TIME: =0% >> "%PROBE_OUT%"
set "BRAND=1"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Manufacturer 2>nul | find /i "MICPE" >nul
if errorlevel 1 set "BRAND=0"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v SupportURL 2>nul | find /i "space.bilibili.com/1978487514" >nul
if errorlevel 1 set "BRAND=0"
if not exist "%SystemRoot%\System32\oemlogo.bmp" set "BRAND=0"
echo brand=%BRAND% >> "%PROBE_OUT%"

rem --- installer -------------------------------------------------------------
echo mark_installer=%TIME: =0% >> "%PROBE_OUT%"
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
echo mark_installer_deploy=%TIME: =0% >> "%PROBE_OUT%"
rem The probe is past the hang-prone UWP section and is about to hand
rem control to the installer .wcs, which can legitimately take a long
rem time on a real deploy; tell the watchdog to stop watching so it
rem cannot mistake a slow deploy for a stalled probe. The watchdog
rem also stops on its own when it sees probe_done=1.
echo stop > "%SystemDrive%\micpe-watchdog-stop.txt"
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
rem A launch needs a running Explorer shell. With no shell, m4 has no
rem PECMD, the probe was attempting this launch when it froze after
rem uwp_appx=1 in run 44161901638, so do not attempt it: report not
rem launchable and return. The caller records 0; m7 verifies the launch
rem with the full image.
rem Run 44285721257: Photos hung the launch, so the wait below is a
rem bounded poll, never a blind sleep. A launch that never shows up
rem still returns 1 and the caller still records 0: a missing app is
rem reported, never skipped and never faked as running.
rem Run 44303866765: the probe died inside the Media (ZuneMusic) call
rem after mark_uwp_launch_media, and the poll cannot be blamed yet:
rem it returned fine for Calculator and Photos. Three markers bracket
rem the launch so the next probe says which line it died on: enter
rem (subroutine reached), start_before / start_after (the start line
rem itself). The caller's uwp_launch_<app> line is the poll-finished
rem witness. Marker values are %TIME% like the section markers; the
rem preceding mark_uwp_launch_<app> line says which app was in flight.
echo mark_uwp_enter=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 exit /b 1

set "UWP_PROC=%~1"
set "UWP_TARGET=%~2"

tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul
if not errorlevel 1 (
    rem Already running, relaunching would be a no-op.
    exit /b 0
)

rem Detached launch, bounded poll (run 44285721257): the old code slept
rem a fixed 7 seconds and then checked once. Photos never appeared and
rem the probe never returned from this subroutine, so nothing after it
rem was ever written. Polling once a second for at most 10 seconds
rem bounds the worst case per app and returns 0 the moment the process
rem shows up, instead of waiting out the whole window. The poll target
rem is the process image name, never the shell target string.
echo mark_uwp_start_before=%TIME: =0% >> "%PROBE_OUT%"
start "" explorer.exe "%UWP_TARGET%"
echo mark_uwp_start_after=%TIME: =0% >> "%PROBE_OUT%"
set "UWP_WAIT=0"
:probe_uwp_poll
ping -n 2 127.0.0.1 >nul 2>&1
tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul
if not errorlevel 1 exit /b 0
set /a UWP_WAIT+=1
if %UWP_WAIT% lss 10 goto :probe_uwp_poll
exit /b 1
