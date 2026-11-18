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

rem --- uwp diagnostics -------------------------------------------------------
rem Run 44349189039: three open questions from run 38, answered with
rem read-only evidence except the two sc start attempts below, which
rem are themselves the experiment (their outcomes are recorded either
rem way, and the watchdog now bounds any stall they cause):
rem  1. UWP apps never appear in tasklist although the start lines return
rem     at once. Online research (eval card §25) gives three stacked
rem     candidates: the AppX deployment service never runs in PE so the
rem     StateRepository database is never generated; the package is not
rem     registered for the SYSTEM session; or activation is refused for
rem     the SYSTEM token outright (UWP needs a user token with Admin
rem     Approval Mode / UAC; WinPE logs on as SYSTEM, and Microsoft's
rem     own docs say WinPE only supports legacy apps). The checks below
rem     say which link is broken: service states before and after a
rem     start attempt, the StateRepository database file, the SYSTEM
rem     profile Packages directory, EnableLUA, and the AppxAllUserStore
rem     entries for the three apps.
rem  2. Explorer is alive (explorer=1, shell_ready=1) but no desktop,
rem     taskbar or folder window ever appears. tasklist /v prints window
rem     titles, so the dump says whether explorer owns any window at
rem     all; the folder-window test below says whether it can create one.
rem     Note the frame host is missing from the image by construction:
rem     ApplicationFrameHost.exe (the process that displays every UWP
rem     app window) appears in no filelist, and neither do
rem     ShellExperienceHost / StartMenuExperienceHost — so even a
rem     successful activation could not show a window. The presence
rem     checks below confirm that at runtime instead of asserting it.
rem  3. The watchdog died in its first 60-second choice wait while the
rem     probe's 1-second choice waits all returned. The watchdog now
rem     waits in 5-second ticks; this section does not touch it.
rem The full tasklist dump goes to micpe-tasklist.txt next to the probe
rem file (build.yml collects it into the verify artifact); the probe file
rem itself only carries the short presence/state keys below.
echo mark_uwp_diag=%TIME: =0% >> "%PROBE_OUT%"
if defined PROBE_DIR (
    set "TASKLIST_OUT=%PROBE_DIR%micpe-tasklist.txt"
) else (
    set "TASKLIST_OUT=%SystemDrive%\micpe-tasklist.txt"
)
echo --- tasklist before UWP section --- > "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>nul
echo tasklist_dump=1 >> "%PROBE_OUT%"
tasklist /fi "imagename eq ApplicationFrameHost.exe" /nh 2>nul | find /i "ApplicationFrameHost.exe" >nul
if errorlevel 1 (echo appframehost=0 >> "%PROBE_OUT%") else (echo appframehost=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq ShellExperienceHost.exe" /nh 2>nul | find /i "ShellExperienceHost.exe" >nul
if errorlevel 1 (echo shellexperiencehost=0 >> "%PROBE_OUT%") else (echo shellexperiencehost=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq StartMenuExperienceHost.exe" /nh 2>nul | find /i "StartMenuExperienceHost.exe" >nul
if errorlevel 1 (echo startmenuexperiencehost=0 >> "%PROBE_OUT%") else (echo startmenuexperiencehost=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq RuntimeBroker.exe" /nh 2>nul | find /i "RuntimeBroker.exe" >nul
if errorlevel 1 (echo runtimebroker=0 >> "%PROBE_OUT%") else (echo runtimebroker=1 >> "%PROBE_OUT%")
rem Explorer-as-process opens a folder window (plan §14), so if no window
rem appears at all, explorer cannot create any window — a deeper break
rem than "no desktop". Start one, wait, and dump tasklist again: the two
rem snapshots say whether a window appeared and what its title is.
echo mark_folder_window=%TIME: =0% >> "%PROBE_OUT%"
start "" explorer.exe "%SystemDrive%\"
choice /c Y /d Y /t 3 >nul
echo --- tasklist after folder-window test --- >> "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>nul
echo folder_window_test=1 >> "%PROBE_OUT%"
echo mark_uwp_svc=%TIME: =0% >> "%PROBE_OUT%"
call :probe_svc AppXSVC appxsvc
call :probe_svc StateRepository staterepo
call :probe_svc AppReadiness appreadiness
rem Start the two deployment services and re-check: if they were only
rem stopped, activation may work after this; if they are missing or
rem refuse to start, the start errorlevel and the after-state say so.
echo mark_uwp_svc_start=%TIME: =0% >> "%PROBE_OUT%"
sc start AppXSVC >nul 2>&1
echo appxsvc_start=%ERRORLEVEL% >> "%PROBE_OUT%"
sc start StateRepository >nul 2>&1
echo staterepo_start=%ERRORLEVEL% >> "%PROBE_OUT%"
call :probe_svc AppXSVC appxsvc_after
call :probe_svc StateRepository staterepo_after
if exist "%ProgramData%\Microsoft\Windows\AppRepository\StateRepository-Machine.srd" (
    echo staterepo_db=1 >> "%PROBE_OUT%"
) else (
    echo staterepo_db=0 >> "%PROBE_OUT%"
)
if exist "%SystemRoot%\System32\config\systemprofile\AppData\Local\Packages" (
    echo sysprofile_packages=1 >> "%PROBE_OUT%"
) else (
    echo sysprofile_packages=0 >> "%PROBE_OUT%"
)
set "ENABLELUA="
for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA 2^>nul ^| find /i "EnableLUA"') do set "ENABLELUA=%%A"
if defined ENABLELUA (echo enablelua=%ENABLELUA% >> "%PROBE_OUT%") else (echo enablelua=missing >> "%PROBE_OUT%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.WindowsCalculator" >nul
if errorlevel 1 (echo appxstore_calc=0 >> "%PROBE_OUT%") else (echo appxstore_calc=1 >> "%PROBE_OUT%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.Photos" >nul
if errorlevel 1 (echo appxstore_photos=0 >> "%PROBE_OUT%") else (echo appxstore_photos=1 >> "%PROBE_OUT%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.ZuneMusic" >nul
if errorlevel 1 (echo appxstore_media=0 >> "%PROBE_OUT%") else (echo appxstore_media=1 >> "%PROBE_OUT%")

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
rem Process image names, verified against the provisioned packages'
rem AppxManifest.xml in the run 27 boot.wim (same 25H2 install.wim
rem source as CI): Calculator runs as CalculatorApp.exe, the new Photos
rem app runs as Microsoft.Lightbox.exe (not Microsoft.Photos.exe, which
rem does not exist in the image), and Media Player runs as
rem Microsoft.Media.Player.exe (not Microsoft.ZuneMusic.exe, which does
rem not exist either). The shell targets below are the manifests'
rem Application Ids and were already right. A 0 still means "the
rem process never appeared in ten polls", never "launch succeeded".
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
call :probe_uwp Microsoft.Lightbox "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_photos=0 >> "%PROBE_OUT%") else (echo uwp_launch_photos=1 >> "%PROBE_OUT%")

echo mark_uwp_launch_media=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp Microsoft.Media.Player "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
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
rem Run 44319967017: the probe died in the Media poll's first round and
rem the loop has three steps (wait, tasklist, find), so each round now
rem writes its own markers (wait_before / wait_after / check_after) and
rem the one-second wait is choice, not ping: ping is the prime suspect
rem for the stall (last proven good ~14:32:49, first proven stuck
rem ~14:33:02, the only event in between being the Media launch), and
rem choice.exe is in the image (20-explorer.txt:126, verified present
rem in the run 27 boot.wim). The marker key carries the process name
rem and round number, so the next partial probe names the exact step.
rem choice /c Y /d Y /t 1 waits one second then takes the default; its
rem errorlevel is ignored on purpose, only the timing matters.
echo mark_uwp_start_before=%TIME: =0% >> "%PROBE_OUT%"
start "" explorer.exe "%UWP_TARGET%"
echo mark_uwp_start_after=%TIME: =0% >> "%PROBE_OUT%"
set "UWP_WAIT=0"
:probe_uwp_poll
echo mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_wait_before=%TIME: =0% >> "%PROBE_OUT%"
choice /c Y /d Y /t 1 >nul
echo mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_wait_after=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul
if not errorlevel 1 exit /b 0
echo mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_check_after=%TIME: =0% >> "%PROBE_OUT%"
set /a UWP_WAIT+=1
if %UWP_WAIT% lss 10 goto :probe_uwp_poll
exit /b 1

:probe_svc
rem %1 = service name, %2 = probe key (run 44349189039).
rem Writes <key>=RUNNING, STOPPED or MISSING. sc query returns 0 when
rem the service exists (even stopped) and 1060 when it does not.
sc query "%~1" >nul 2>&1
if errorlevel 1 (
    echo %~2=MISSING >> "%PROBE_OUT%"
    exit /b 0
)
sc query "%~1" 2>nul | find /i "RUNNING" >nul
if not errorlevel 1 (
    echo %~2=RUNNING >> "%PROBE_OUT%"
) else (
    echo %~2=STOPPED >> "%PROBE_OUT%"
)
exit /b 0
