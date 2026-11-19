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

rem Local mirror (run 44386689307): every section marker is written to
rem this file on the PE system drive FIRST and to the share second, so
rem a wedged share write cannot hide how far the probe got. The share
rem file stays the asserted probe file; the local file is diagnostics
rem only. The detached probe-sync.cmd (started below next to the
rem watchdog) echoes the local file's last line to the serial log every
rem few seconds, which the host reads without the share: if the serial
rem markers keep coming while the share probe stops growing, the guest
rem is alive and the share is wedged; if the serial markers stop too,
rem the guest itself froze. The poll markers are not mirrored (they
rem fire every second; the section markers bracket the freeze points
rem runs 39/40 actually hit).
set "PROBE_LOCAL=%SystemDrive%\micpe-probe-local.txt"

> "%PROBE_LOCAL%" echo boot=1 & > "%PROBE_OUT%" echo boot=1
>> "%PROBE_LOCAL%" echo share=%SHARE% & >> "%PROBE_OUT%" echo share=%SHARE%
if defined PROBE_DIR >> "%PROBE_LOCAL%" echo share_drive=%PROBE_DIR%
if defined PROBE_DIR >> "%PROBE_OUT%" echo share_drive=%PROBE_DIR%

rem Mirror drive (run 44428428849): the serial channel is dead, so the
rem local mirror needs a retrieval path that does not depend on the
rem suspect share. The harness attaches a second vvfat volume
rem carrying a micpe-mirror.txt sentinel; the drive holding it is the
rem mirror. Found by sentinel, never by letter, so a letter shift
rem cannot misidentify it. The detached probe-mirror.cmd (started
rem below next to the sync) copies the local file there every few
rem seconds; the host reads it straight from the mirror directory
rem after QEMU exits. mirror=0 means no mirror drive was attached
rem (old harness); the probe runs on without it. This scan MUST sit
rem after the boot=1 line above: that line truncates both probe files
rem with a single >, so a mirror line written before it would be wiped
rem (CI run 44440362261 proved it: mirror=0 never landed).
set "MIRROR_DIR="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\micpe-mirror.txt" set "MIRROR_DIR=%%D:\"
)
if defined MIRROR_DIR (echo mirror=1 >> "%PROBE_LOCAL%" & echo mirror=1 >> "%PROBE_OUT%") else (echo mirror=0 >> "%PROBE_LOCAL%" & echo mirror=0 >> "%PROBE_OUT%")
if defined MIRROR_DIR (echo mirror_drive=%MIRROR_DIR% >> "%PROBE_LOCAL%" & echo mirror_drive=%MIRROR_DIR% >> "%PROBE_OUT%")

rem Drive-letter enumeration (run 44441708839): mirror=0 alone cannot say
rem whether the mirror volume never mounted or mounted without its
rem sentinel. List every drive letter the guest can see, so the two
rem cases split: a mirror letter present with mirror=0 means the volume
rem mounted but the sentinel is invisible (vvfat quirk); a letter absent
rem means the volume never enumerated. Written right after the mirror
rem scan, so it lands in both probe files even if the probe dies later.
set "DRIVES="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist "%%D:\" set "DRIVES=!DRIVES!%%D"
echo drives=%DRIVES% >> "%PROBE_LOCAL%" & echo drives=%DRIVES% >> "%PROBE_OUT%"

rem Serial channel test (run 44410311576): probe-sync.cmd wrote zero sync
rem lines in run 41 although it lived until the stop flag (the detached
rem cmd 1724 only disappears from the end snapshot, after the flag was
rem written), so the channel itself is the suspect, not the sync process.
rem This line is the decisive test: if it lands in micpe-serial.log the
rem channel works. The com1 key records whether cmd.exe could open COM1
rem at all; serial_sys / serialcomm say whether the driver and the port
rem enumeration exist. A com1=0 here convicts the channel: the local
rem mirror then needs a different retrieval path than the serial log.
echo sync_test=%TIME: =0% > COM1 2>nul
rem A failed output redirect leaves errorlevel UNCHANGED (CI runs
rem 44425584830 and 44426492643 proved it in both directions: after
rem a failing redirect the errorlevel was whatever the previous
rem command left — 0 when the previous command had succeeded, 1
rem when it had failed), so the redirect above can never report
rem com1 — it is only the end-to-end proof, seen as a sync_test line
rem in micpe-serial.log iff the channel works. The actual open test
rem is copy: it fails with errorlevel 1 when the port cannot be
rem opened. copy is a cmd.exe internal command, so it needs no exe
rem on PATH.
copy /y nul COM1 >nul 2>&1
if errorlevel 1 (echo com1=0 >> "%PROBE_LOCAL%" & echo com1=0 >> "%PROBE_OUT%") else (echo com1=1 >> "%PROBE_LOCAL%" & echo com1=1 >> "%PROBE_OUT%")
if exist "%SystemRoot%\System32\drivers\serial.sys" (echo serial_sys=1 >> "%PROBE_LOCAL%" & echo serial_sys=1 >> "%PROBE_OUT%") else (echo serial_sys=0 >> "%PROBE_LOCAL%" & echo serial_sys=0 >> "%PROBE_OUT%")
rem No pipeline here on purpose (run 44135105700): a command missing
rem from PATH inside a pipeline kills the batch silently, and reg.exe
rem is not on the restricted PATH of the mechanism test. A bare
rem reg query only sets errorlevel when it fails, so the batch
rem continues and records serialcomm=0 either way. The /v form reads
rem the \Device\Serial0 value directly instead of piping the whole
rem key through find.
reg query "HKLM\HARDWARE\DEVICEMAP\SERIALCOMM" /v \Device\Serial0 >nul 2>&1
if errorlevel 1 (echo serialcomm=0 >> "%PROBE_LOCAL%" & echo serialcomm=0 >> "%PROBE_OUT%") else (echo serialcomm=1 >> "%PROBE_LOCAL%" & echo serialcomm=1 >> "%PROBE_OUT%")

rem Serial enumeration (run 44428428849): serial.sys is in the image
rem (serial_sys=1) but the port was never enumerated (serialcomm=0) —
rem file present is not driver loaded. These keys say which link is
rem broken: the ACPI device, the Serial service state, or its Start
rem value. serial_enum=0 means QEMU/OVMF never presented the 16550
rem port to Windows (the channel is dead at the hardware level);
rem serial_enum=1 with serial_start=0x4 means the driver is disabled
rem (revivable from CI by setting Start at image build time — never
rem by a registry import inside PE, user decision 2026-11-17 23:43);
rem serial_enum=1 with Start 0x3/0x2/0x1/0x0 means the driver should
rem have loaded and did not. Diagnosis only: no service is started
rem here, so this block cannot change the freeze behaviour.
rem The service states go through :probe_svc (third argument mirrors
rem them to the local file); the Start values use the EnableLUA parse
rem shape (for /f tokens=3 over reg query /v, find matches only the
rem value line); the enum check is a bare reg query, so a missing key
rem only sets errorlevel and the batch continues. sc.exe is in the
rem image (:probe_svc already uses it for AppXSVC) and the mechanism
rem harness copies it in alongside reg.exe.
call :probe_svc Serial serial_svc "%PROBE_LOCAL%"
call :probe_svc Serenum serenum_svc "%PROBE_LOCAL%"
set "SERIAL_START="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\Serial" /v Start 2^>nul ^| find /i "Start"') do set "SERIAL_START=%%A"
if defined SERIAL_START (echo serial_start=%SERIAL_START% >> "%PROBE_LOCAL%" & echo serial_start=%SERIAL_START% >> "%PROBE_OUT%") else (echo serial_start=missing >> "%PROBE_LOCAL%" & echo serial_start=missing >> "%PROBE_OUT%")
set "SERENUM_START="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\Serenum" /v Start 2^>nul ^| find /i "Start"') do set "SERENUM_START=%%A"
if defined SERENUM_START (echo serenum_start=%SERENUM_START% >> "%PROBE_LOCAL%" & echo serenum_start=%SERENUM_START% >> "%PROBE_OUT%") else (echo serenum_start=missing >> "%PROBE_LOCAL%" & echo serenum_start=missing >> "%PROBE_OUT%")
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\PNP0501" >nul 2>&1
if errorlevel 1 (echo serial_enum=0 >> "%PROBE_LOCAL%" & echo serial_enum=0 >> "%PROBE_OUT%") else (echo serial_enum=1 >> "%PROBE_LOCAL%" & echo serial_enum=1 >> "%PROBE_OUT%")

rem Watchdog (run 44285721257): if this probe stalls or dies mid-run, no
rem probe_done line is ever written and the CI host waits out the full
rem 45 minutes. A detached watcher notices the probe file going quiet
rem and records probe_failed=1, which ends the wait early without
rem changing the verdict: probe_failed still fails the run, see
rem Assert-Probe. The watcher only runs when its own script made it
rem into the image; a missing file is a silent no-op.
if exist "%SystemRoot%\System32\probe-watchdog.cmd" start "" /min cmd /c %SystemRoot%\System32\probe-watchdog.cmd "%PROBE_OUT%"

rem Local-mirror sync (run 44386689307): the detached probe-sync.cmd
rem echoes the local mirror's last line to the serial log, so the host
rem can tell a wedged share from a frozen guest. It stops on its own
rem when it sees probe_done=1 in the local file, or when probe.cmd
rem writes the stop flag before the long installer deploy. Same
rem missing-file-is-a-silent-no-op rule as the watchdog above.
if exist "%SystemRoot%\System32\probe-sync.cmd" start "" /min cmd /c %SystemRoot%\System32\probe-sync.cmd "%PROBE_LOCAL%"

rem Local-mirror copy (run 44428428849): the detached probe-mirror.cmd
rem copies the local file to the mirror drive every few seconds, so the
rem host can read it without the share. Only when a mirror drive was
rem found (MIRROR_DIR set) and the script made it into the image; a
rem missing file is a silent no-op, same rule as the watchdog/sync.
if defined MIRROR_DIR (
    if exist "%SystemRoot%\System32\probe-mirror.cmd" start "" /min cmd /c %SystemRoot%\System32\probe-mirror.cmd "%PROBE_LOCAL%" "%MIRROR_DIR%"
)

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
echo mark_shell_ready=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_shell_ready=%TIME: =0% >> "%PROBE_OUT%"
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
echo mark_shell_ping_before=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_shell_ping_before=%TIME: =0% >> "%PROBE_OUT%"
ping -n 16 127.0.0.1 >nul 2>&1
echo mark_shell_ping_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_shell_ping_after=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
set "SHELL_EXPLORER=%ERRORLEVEL%"
echo mark_shell_check_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_shell_check_after=%TIME: =0% >> "%PROBE_OUT%"
rem Run 44428428849: explorer's CPU time was already frozen at 0:00:13 in
rem the first tasklist snapshot, so the snapshots alone cannot say when
rem it stopped working — at startup, or later. Record its CPU time at
rem each liveness check (shell + after each UWP launch + probe end); a
rem time that never advances across segments means it never did
rem meaningful work after start. The errorlevel is captured first
rem because the call below would clobber it.
call :probe_explorer_cpu shell
if "%SHELL_EXPLORER%"=="0" (echo shell_ready=1 >> "%PROBE_OUT%") else (echo shell_ready=0 >> "%PROBE_OUT%")

rem --- network ---------------------------------------------------------------
echo mark_network=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_network=%TIME: =0% >> "%PROBE_OUT%"
set "IPV4="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /c:"IPv4"') do (
    if not defined IPV4 set "IPV4=%%A"
)
if defined IPV4 (echo network=!IPV4: =! >> "%PROBE_OUT%") else (echo network=pending >> "%PROBE_OUT%")

rem --- input method ----------------------------------------------------------
echo mark_ime=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_ime=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload" 2>nul | find /i "0804" >nul
if errorlevel 1 (echo ime=0 >> "%PROBE_OUT%") else (echo ime=1 >> "%PROBE_OUT%")

rem --- uwp diagnostics -------------------------------------------------------
rem Run 44349189039: three open questions from run 38, answered with
rem read-only evidence. Run 44365018616 control: the probe and the
rem watchdog both stopped within ~15 seconds of the two sc start calls
rem in run 39 (probe after the Photos result line, watchdog after tick 8/12),
rem so sc start is the prime suspect for the freeze — but explorer was
rem already Not Responding before any sc start, so it cannot be
rem convicted yet. This round the services are NOT started: one
rem variable at a time. Their last exit codes are recorded instead
rem (sc queryex WIN32_EXIT_CODE), and each AppxAllUserStore query is
rem bracketed with before/after markers so the next partial probe says
rem whether it died inside a reg query or in the append write after it.
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
echo mark_uwp_diag=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_diag=%TIME: =0% >> "%PROBE_OUT%"
if defined PROBE_DIR (
    set "TASKLIST_OUT=%PROBE_DIR%micpe-tasklist.txt"
) else (
    set "TASKLIST_OUT=%SystemDrive%\micpe-tasklist.txt"
)
rem Run 44441708839: explorer was already CPU-frozen in the first
rem tasklist snapshot, so the snapshots alone cannot say when it stopped
rem working. The shell CPU call runs before shell_ready; this one runs
rem right before the first snapshot, so the two bracket the
rem network/ime/diagnostics gap.
call :probe_explorer_cpu preuwp
echo --- tasklist before UWP section --- > "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>nul
echo tasklist_dump=1 >> "%PROBE_OUT%"
rem Run 46 (explorer breakpoint): which services live in the svchost
rem that burned ~1:45 of CPU in run 45 (PID 1072)? tasklist /v only
rem shows the CPU time, not the hosted services. The /svc dump names
rem them; the coordinator reads PID 1072 out of the artifact.
echo --- tasklist /svc --- >> "%TASKLIST_OUT%"
tasklist /svc >> "%TASKLIST_OUT%" 2>nul
echo svc_dump=1 >> "%PROBE_OUT%"
rem Run 46 (mirror, §30.5.2): mirror=0 with drives=CDX — the volume is
rem visible but the sentinel is not. Dump the mirror volume's root so
rem the next run can say whether the volume is empty (vvfat delivered
rem nothing) or holds files under a different name. MIRROR_DIR is the
rem sentinel-found drive; with no sentinel, fall back to D: (the
rem second vvfat volume on the CI layout) when it exists.
set "MIRROR_ROOT="
if defined MIRROR_DIR set "MIRROR_ROOT=%MIRROR_DIR%"
if not defined MIRROR_ROOT if exist "D:\" set "MIRROR_ROOT=D:\"
if defined MIRROR_ROOT (
    echo --- dir %MIRROR_ROOT% --- >> "%TASKLIST_OUT%"
    dir "%MIRROR_ROOT%" >> "%TASKLIST_OUT%" 2>nul
    set "MIRROR_ROOT_FILES="
    for /f %%F in ('dir /b "%MIRROR_ROOT%" 2^>nul ^| find /c /v ""') do set "MIRROR_ROOT_FILES=%%F"
    if defined MIRROR_ROOT_FILES (echo mirror_root_files=!MIRROR_ROOT_FILES: =! >> "%PROBE_OUT%") else (echo mirror_root_files=missing >> "%PROBE_OUT%")
    echo mirror_root_drive=%MIRROR_ROOT% >> "%PROBE_OUT%"
) else (
    echo mirror_root_files=missing >> "%PROBE_OUT%"
)
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
echo mark_folder_window=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_folder_window=%TIME: =0% >> "%PROBE_OUT%"
start "" explorer.exe "%SystemDrive%\"
choice /c Y /d Y /t 3 >nul
echo --- tasklist after folder-window test --- >> "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>nul
echo folder_window_test=1 >> "%PROBE_OUT%"
rem What explorer has loaded: a hung explorer with no window may be stuck
rem in a shell extension or a missing shell host. The module list says
rem which DLLs are in it; it goes into the same tasklist file so the
rem artifact upload needs no change.
echo --- tasklist /m explorer.exe --- >> "%TASKLIST_OUT%"
tasklist /m /fi "imagename eq explorer.exe" >> "%TASKLIST_OUT%" 2>nul
echo mark_uwp_svc=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_svc=%TIME: =0% >> "%PROBE_OUT%"
call :probe_svc AppXSVC appxsvc
call :probe_svc StateRepository staterepo
call :probe_svc AppReadiness appreadiness
rem The two deployment services are NOT started this round (control
rem for run 44365018616 — see the section header). Record each stopped
rem service's last exit code instead: run 39 showed sc start returning
rem 0 while the service stayed STOPPED, which means it started and
rem died at once or SCM accepted a request it could not honour — the
rem exit code says which.
echo mark_uwp_svc_exitcode=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_svc_exitcode=%TIME: =0% >> "%PROBE_OUT%"
rem Run 44386689307: both parses came back missing — the WIN32_EXIT_CODE
rem line never appeared, so the exit codes of the two STOPPED services
rem are still unknown. Dump the raw queryex output into the tasklist
rem file first; if queryex prints a different layout in PE (or nothing
rem at all) the raw text says so, instead of the parse silently
rem swallowing it.
echo --- sc queryex AppXSVC --- >> "%TASKLIST_OUT%"
sc queryex AppXSVC >> "%TASKLIST_OUT%" 2>&1
echo --- sc queryex StateRepository --- >> "%TASKLIST_OUT%"
sc queryex StateRepository >> "%TASKLIST_OUT%" 2>&1
set "APPXSVC_EXIT="
for /f "tokens=3" %%A in ('sc queryex AppXSVC 2^>nul ^| find /i "WIN32_EXIT_CODE"') do set "APPXSVC_EXIT=%%A"
if defined APPXSVC_EXIT (echo appxsvc_exitcode=%APPXSVC_EXIT% >> "%PROBE_OUT%") else (echo appxsvc_exitcode=missing >> "%PROBE_OUT%")
set "STATEREPO_EXIT="
for /f "tokens=3" %%A in ('sc queryex StateRepository 2^>nul ^| find /i "WIN32_EXIT_CODE"') do set "STATEREPO_EXIT=%%A"
if defined STATEREPO_EXIT (echo staterepo_exitcode=%STATEREPO_EXIT% >> "%PROBE_OUT%") else (echo staterepo_exitcode=missing >> "%PROBE_OUT%")
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
rem Run 44365018616: the probe stopped after the Photos result line, in the
rem third identical reg query or in the append write after it — the two
rem look the same in the probe file. Each query below is bracketed:
rem the _query marker is written before it runs, the _after marker
rem right after it returns (the errorlevel is captured first, because
rem the marker echo would clobber it). Last line _query with no _after
rem means the query itself hung; last line _after with no result means
rem the append write hung.
echo mark_appxstore_calc_query=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_calc_query=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.WindowsCalculator" >nul
set "APPXSTORE_CALC=%ERRORLEVEL%"
echo mark_appxstore_calc_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_calc_after=%TIME: =0% >> "%PROBE_OUT%"
if "%APPXSTORE_CALC%"=="0" (echo appxstore_calc=1 >> "%PROBE_OUT%") else (echo appxstore_calc=0 >> "%PROBE_OUT%")
echo mark_appxstore_photos_query=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_photos_query=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.Photos" >nul
set "APPXSTORE_PHOTOS=%ERRORLEVEL%"
echo mark_appxstore_photos_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_photos_after=%TIME: =0% >> "%PROBE_OUT%"
if "%APPXSTORE_PHOTOS%"=="0" (echo appxstore_photos=1 >> "%PROBE_OUT%") else (echo appxstore_photos=0 >> "%PROBE_OUT%")
echo mark_appxstore_media_query=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_media_query=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.ZuneMusic" >nul
set "APPXSTORE_MEDIA=%ERRORLEVEL%"
echo mark_appxstore_media_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_media_after=%TIME: =0% >> "%PROBE_OUT%"
if "%APPXSTORE_MEDIA%"=="0" (echo appxstore_media=1 >> "%PROBE_OUT%") else (echo appxstore_media=0 >> "%PROBE_OUT%")
rem Run 45 (UWP frame host): the two SystemApps hosts are registered in
rem AppxAllUserStore\InboxApplications by the SOFTWARE hive swap
rem (Install-ExplorerShell), not by a build-time write — these queries
rem confirm the swap carried them. No mark_ markers: the three queries
rem above already proved this pattern does not hang.
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.ShellExperienceHost" >nul
set "APPXSTORE_SEH=%ERRORLEVEL%"
if "%APPXSTORE_SEH%"=="0" (echo appxstore_shellexperiencehost=1 >> "%PROBE_OUT%") else (echo appxstore_shellexperiencehost=0 >> "%PROBE_OUT%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.StartMenuExperienceHost" >nul
set "APPXSTORE_SMEH=%ERRORLEVEL%"
if "%APPXSTORE_SMEH%"=="0" (echo appxstore_startmenuexperiencehost=1 >> "%PROBE_OUT%") else (echo appxstore_startmenuexperiencehost=0 >> "%PROBE_OUT%")
rem Run 46 (explorer breakpoint, §31.9 #3): in run 45 explorer died
rem during the diagnostics — last alive evidence the second tasklist
rem snapshot, first dead evidence the Calculator guard — so the death
rem window spans the whole appxstore/host-query stretch. Check liveness
rem once mid-diagnosis (plus a CPU sample) to split that window at the
rem queries instead of spanning the section.
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_mid_diag=0 >> "%PROBE_OUT%") else (echo explorer_mid_diag=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu diag

rem --- uwp -------------------------------------------------------------------
echo mark_uwp_appx=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_appx=%TIME: =0% >> "%PROBE_OUT%"
if exist "%SystemRoot%\System32\AppXDeploymentClient.dll" (
    echo uwp_appx=1 >> "%PROBE_OUT%"
) else (
    echo uwp_appx=0 >> "%PROBE_OUT%"
)
rem Run 45 (UWP frame host): the frame host chain is now extracted into
rem the image; record whether the files are actually in the running
rem image (file presence, not process presence — the appframehost= key
rem above says whether the process is running). The build-time assert
rem already guarantees the files are in boot.wim; these keys confirm
rem %SystemRoot% resolves to the same files at runtime. The StateRepository
rem service DLL is checked by its on-disk name Windows.StateRepository.dll
rem (the hive spells it windows.staterepository.dll — same file, NTFS names
rem are case-insensitive, and it is already extracted by 20-explorer.txt).
rem No mark_ markers: the three appxstore queries below already proved this
rem pattern does not hang, so no freeze bracketing is needed here.
if exist "%SystemRoot%\System32\ApplicationFrameHost.exe" if exist "%SystemRoot%\System32\RuntimeBroker.exe" if exist "%SystemRoot%\SystemApps\ShellExperienceHost_cw5n1h2txyewy\ShellExperienceHost.exe" if exist "%SystemRoot%\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe" (echo framehost_files=1 >> "%PROBE_OUT%") else (echo framehost_files=0 >> "%PROBE_OUT%")
if exist "%SystemRoot%\System32\Windows.StateRepository.dll" if exist "%SystemRoot%\System32\AppReadiness.dll" (echo framehost_dlls=1 >> "%PROBE_OUT%") else (echo framehost_dlls=0 >> "%PROBE_OUT%")

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
echo mark_uwp_launch_calculator=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_launch_calculator=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp CalculatorApp "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_calculator=0 >> "%PROBE_OUT%") else (echo uwp_launch_calculator=1 >> "%PROBE_OUT%")
rem Run 44410311576: explorer died inside the run, so the launch after
rem each poll says whether it was still alive then. The guard of the
rem NEXT launch only says so one launch later; this check splits the
rem death window to a single launch (in run 41: alive at the Photos
rem guard 22:50:16, gone at the Media guard 22:50:46).
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_after_calculator=0 >> "%PROBE_LOCAL%" & echo explorer_after_calculator=0 >> "%PROBE_OUT%") else (echo explorer_after_calculator=1 >> "%PROBE_LOCAL%" & echo explorer_after_calculator=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu calculator

echo mark_uwp_launch_photos=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_launch_photos=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp Microsoft.Lightbox "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"
if errorlevel 1 (echo uwp_launch_photos=0 >> "%PROBE_OUT%") else (echo uwp_launch_photos=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_after_photos=0 >> "%PROBE_LOCAL%" & echo explorer_after_photos=0 >> "%PROBE_OUT%") else (echo explorer_after_photos=1 >> "%PROBE_LOCAL%" & echo explorer_after_photos=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu photos

echo mark_uwp_launch_media=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_launch_media=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp Microsoft.Media.Player "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
if errorlevel 1 (echo uwp_launch_media=0 >> "%PROBE_OUT%") else (echo uwp_launch_media=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_after_media=0 >> "%PROBE_LOCAL%" & echo explorer_after_media=0 >> "%PROBE_OUT%") else (echo explorer_after_media=1 >> "%PROBE_LOCAL%" & echo explorer_after_media=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu media
endlocal
rem Run 45 (UWP frame host): the three launches above may have started the
rem deployment services on demand (AppXSVC is manual-start with trigger
rem info; StateRepository is automatic but may have failed to start at
rem boot). Re-check their states after the launches, so a launch that
rem worked is not misread as "the services never started". The _after
rem keys are diagnostic only — no stage table asserts them.
call :probe_svc AppXSVC appxsvc_after
call :probe_svc StateRepository staterepo_after
call :probe_svc AppReadiness appreadiness_after

rem --- cross-check (run 46) ------------------------------------------------
rem Run 45's three uwp_launch_*=0 are NOT a cross-validation: all three
rem failed at the explorer guard, before any real launch attempt, so
rem "can other UWP apps open" has no evidence either way. This section
rem retries each app WITHOUT the guard, through a launch path that does
rem not go through the explorer.exe process: a plain ShellExecute of the
rem shell:AppsFolder target (start "" "shell:AppsFolder\..."), whose
rem parsing and activation run in-process via shell32/twinapi instead
rem of being handed to the shell process. If an app process appears,
rem the UWP chain works and the break is explorer-side (config/files);
rem if none appears, the UWP chain stays suspect — with the caveat that
rem the start path itself may still need the shell, so a 0 here is read
rem together with the module diff (eval card §32.3), not alone.
rem The calls run inside their own DisableDelayedExpansion block (the
rem bang in the AppUserModelId must survive, U3); the after-checks sit
rem after endlocal because they carry no bang.
echo mark_xcheck=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck=%TIME: =0% >> "%PROBE_OUT%"
rem Truth checks use the System32 tasklist by full path (C1/C1b): a
rem bare tasklist is shadowed by the harness copy on the runner,
rem whose /fi is rejected, so a bare check would always read 0.
"%SystemRoot%\System32\tasklist.exe" /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo xcheck_explorer_before=0 >> "%PROBE_OUT%") else (echo xcheck_explorer_before=1 >> "%PROBE_OUT%")
setlocal DisableDelayedExpansion
echo mark_xcheck_launch_calculator=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_launch_calculator=%TIME: =0% >> "%PROBE_OUT%"
call :probe_xcheck CalculatorApp "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
if errorlevel 1 (echo xcheck_launch_calculator=0 >> "%PROBE_OUT%") else (echo xcheck_launch_calculator=1 >> "%PROBE_OUT%")
echo mark_xcheck_launch_photos=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_launch_photos=%TIME: =0% >> "%PROBE_OUT%"
call :probe_xcheck Microsoft.Lightbox "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"
if errorlevel 1 (echo xcheck_launch_photos=0 >> "%PROBE_OUT%") else (echo xcheck_launch_photos=1 >> "%PROBE_OUT%")
echo mark_xcheck_launch_media=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_launch_media=%TIME: =0% >> "%PROBE_OUT%"
call :probe_xcheck Microsoft.Media.Player "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
if errorlevel 1 (echo xcheck_launch_media=0 >> "%PROBE_OUT%") else (echo xcheck_launch_media=1 >> "%PROBE_OUT%")
endlocal
"%SystemRoot%\System32\tasklist.exe" /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo xcheck_explorer_after=0 >> "%PROBE_OUT%") else (echo xcheck_explorer_after=1 >> "%PROBE_OUT%")
"%SystemRoot%\System32\tasklist.exe" /fi "imagename eq ApplicationFrameHost.exe" /nh 2>nul | find /i "ApplicationFrameHost.exe" >nul
if errorlevel 1 (echo xcheck_framehost_after=0 >> "%PROBE_OUT%") else (echo xcheck_framehost_after=1 >> "%PROBE_OUT%")

rem --- payload ---------------------------------------------------------------
echo mark_payload=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_payload=%TIME: =0% >> "%PROBE_OUT%"
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
echo mark_brand=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_brand=%TIME: =0% >> "%PROBE_OUT%"
set "BRAND=1"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Manufacturer 2>nul | find /i "MICPE" >nul
if errorlevel 1 set "BRAND=0"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v SupportURL 2>nul | find /i "space.bilibili.com/1978487514" >nul
if errorlevel 1 set "BRAND=0"
if not exist "%SystemRoot%\System32\oemlogo.bmp" set "BRAND=0"
echo brand=%BRAND% >> "%PROBE_OUT%"

rem --- installer -------------------------------------------------------------
echo mark_installer=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_installer=%TIME: =0% >> "%PROBE_OUT%"
rem M6: run the installer in -cli -discoveronly mode so it writes
rem installer_scan / installer_source / installer_name / installer_path
rem into the same probe file (design §6). M7: when a source was found and
rem data disks are attached (plan Task 17 Step 6), the deploy step below
rem calls -cli -deploy, which writes installer_deploy after a successful
rem apply + boot repair.
rem The .wcs path is checked first so a missing installer fails loudly
rem (installer_scan=0) instead of silently leaving the key out.
rem Run 44386689307: the probe stopped after brand=1 and never wrote
rem mark_installer, so the next partial probe cannot say whether it
rem died entering this section or inside the .wcs call. The
rem before/after pair below brackets the call the same way the reg
rem query markers do.
echo mark_installer_before=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_installer_before=%TIME: =0% >> "%PROBE_OUT%"
set "MICPE_PROBE_FILE=%PROBE_OUT%"
if exist "%SystemDrive%\Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs" (
    pecmd.exe "%SystemDrive%\Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs" -cli -discoveronly
) else (
    echo installer_scan=0 >> "%PROBE_OUT%"
)
echo mark_installer_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_installer_after=%TIME: =0% >> "%PROBE_OUT%"

rem --- installer deploy (M7 harness, plan Task 17 Step 6) --------------------
echo mark_installer_deploy=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_installer_deploy=%TIME: =0% >> "%PROBE_OUT%"
echo mark_installer_deploy_before=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_installer_deploy_before=%TIME: =0% >> "%PROBE_OUT%"
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

rem Run 44386689307: the deploy section is bracketed the same way as the
rem scan above, so a probe that dies inside the .wcs deploy call leaves
rem before without after. The end snapshot below is the last thing the
rem probe writes before probe_done: explorer was already Not Responding
rem before the UWP diagnostics in run 39, and its module list is
rem complete, so a second dump says whether it ever built a window or
rem changed state during the run.
echo mark_installer_deploy_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_installer_deploy_after=%TIME: =0% >> "%PROBE_OUT%"
echo --- tasklist at probe end --- >> "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>nul
echo --- tasklist /m explorer.exe at probe end --- >> "%TASKLIST_OUT%"
tasklist /m /fi "imagename eq explorer.exe" >> "%TASKLIST_OUT%" 2>nul
rem Run 44410311576: explorer hung and then died inside the run with no
rem crash handler in any snapshot, so the end keys say whether a crash
rem was ever reported (WerFault) and whether the compositor outlived
rem the shell (dwm). Absence of WerFault in all three snapshots is
rem itself evidence: a silent exit, not a reported crash.
tasklist /fi "imagename eq WerFault.exe" /nh 2>nul | find /i "WerFault.exe" >nul
if errorlevel 1 (echo werfault_end=0 >> "%PROBE_LOCAL%" & echo werfault_end=0 >> "%PROBE_OUT%") else (echo werfault_end=1 >> "%PROBE_LOCAL%" & echo werfault_end=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq dwm.exe" /nh 2>nul | find /i "dwm.exe" >nul
if errorlevel 1 (echo dwm_end=0 >> "%PROBE_LOCAL%" & echo dwm_end=0 >> "%PROBE_OUT%") else (echo dwm_end=1 >> "%PROBE_LOCAL%" & echo dwm_end=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu end
rem Run 44428428849: explorer exits silently (no WerFault in any snapshot),
rem so a crash report would only exist if WerFault failed to launch at
rem all. List the WER queues for an explorer-named entry — pure file
rem checks, no service call, so they cannot stall the probe this late.
rem No event-log query here: a silent exit writes no Event 1000/1001,
rem and wevtutil against a stopped log service is a stall risk one line
rem before probe_done.
set "WER_EXPLORER=0"
if exist "%ProgramData%\Microsoft\Windows\WER\ReportQueue" (
    dir /b "%ProgramData%\Microsoft\Windows\WER\ReportQueue" 2>nul | find /i "explorer" >nul
    if not errorlevel 1 set "WER_EXPLORER=1"
    rem Run 44441708839: wer_explorer=1 alone cannot say whether the entry
    rem is this run's death or an old one. Copy each matching entry's
    rem name and last-write time too: the name carries the faulting
    rem binary and the report kind, the time is compared against the
    rem death window.
    for /f "delims=" %%N in ('dir /b "%ProgramData%\Microsoft\Windows\WER\ReportQueue" 2^>nul ^| find /i "explorer"') do (
        echo wer_explorer_name=%%N >> "%PROBE_LOCAL%" & echo wer_explorer_name=%%N >> "%PROBE_OUT%"
        for %%T in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\%%N") do echo wer_explorer_time=%%~tT >> "%PROBE_LOCAL%" & echo wer_explorer_time=%%~tT >> "%PROBE_OUT%"
    )
)
if exist "%ProgramData%\Microsoft\Windows\WER\ReportArchive" (
    dir /b "%ProgramData%\Microsoft\Windows\WER\ReportArchive" 2>nul | find /i "explorer" >nul
    if not errorlevel 1 set "WER_EXPLORER=1"
    for /f "delims=" %%N in ('dir /b "%ProgramData%\Microsoft\Windows\WER\ReportArchive" 2^>nul ^| find /i "explorer"') do (
        echo wer_explorer_archive_name=%%N >> "%PROBE_LOCAL%" & echo wer_explorer_archive_name=%%N >> "%PROBE_OUT%"
        for %%T in ("%ProgramData%\Microsoft\Windows\WER\ReportArchive\%%N") do echo wer_explorer_archive_time=%%~tT >> "%PROBE_LOCAL%" & echo wer_explorer_archive_time=%%~tT >> "%PROBE_OUT%"
    )
)
rem Run 46 (explorer breakpoint): the queue name/time only says "an
rem explorer crash happened at 06:35". The faulting module, exception
rem code and offset live in the Report.wer text file inside each entry.
rem Copy every explorer entry's Report.wer into the tasklist file
rem (already collected) so the host can read the breakpoint without a
rem second artifact; the count key says how many reports were found.
rem Pure file reads, no service call, so they cannot stall the probe.
rem A for /d pattern with no match runs once with the literal pattern,
rem so the if exist guard is what skips the no-entry case.
set "WER_REPORTS=0"
for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\*explorer*") do (
    if exist "%%D\Report.wer" (
        echo --- WER ReportQueue %%~nxD --- >> "%TASKLIST_OUT%"
        type "%%D\Report.wer" >> "%TASKLIST_OUT%" 2>nul
        set /a WER_REPORTS+=1
    )
)
for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportArchive\*explorer*") do (
    if exist "%%D\Report.wer" (
        echo --- WER ReportArchive %%~nxD --- >> "%TASKLIST_OUT%"
        type "%%D\Report.wer" >> "%TASKLIST_OUT%" 2>nul
        set /a WER_REPORTS+=1
    )
)
echo wer_reports=%WER_REPORTS% >> "%PROBE_LOCAL%" & echo wer_reports=%WER_REPORTS% >> "%PROBE_OUT%"
echo wer_explorer=%WER_EXPLORER% >> "%PROBE_LOCAL%" & echo wer_explorer=%WER_EXPLORER% >> "%PROBE_OUT%"

rem Run 46 (explorer breakpoint): a silent exit writes no Event
rem 1000/1001, but the log files themselves say whether the event-log
rem service ran at all in this PE. wevtutil is NOT queried: against a
rem stopped log service it is a stall risk one line before probe_done
rem (see the note above). Record existence + size, copy the files to
rem the share for host-side parsing, and let the host read explorer
rem entries from the copy. A locked file fails the copy silently; the
rem _copy key says whether it landed.
set "EVTX_SYSTEM=0"
if exist "%SystemRoot%\System32\winevt\Logs\System.evtx" (
    set "EVTX_SYSTEM=1"
    for %%F in ("%SystemRoot%\System32\winevt\Logs\System.evtx") do echo evtx_system_size=%%~zF >> "%PROBE_OUT%"
    if defined PROBE_DIR copy /y "%SystemRoot%\System32\winevt\Logs\System.evtx" "%PROBE_DIR%micpe-system.evtx" >nul 2>&1
)
echo evtx_system=%EVTX_SYSTEM% >> "%PROBE_OUT%"
if exist "%PROBE_DIR%micpe-system.evtx" (echo evtx_system_copy=1 >> "%PROBE_OUT%") else (echo evtx_system_copy=0 >> "%PROBE_OUT%")
set "EVTX_APP=0"
if exist "%SystemRoot%\System32\winevt\Logs\Application.evtx" (
    set "EVTX_APP=1"
    for %%F in ("%SystemRoot%\System32\winevt\Logs\Application.evtx") do echo evtx_app_size=%%~zF >> "%PROBE_OUT%"
    if defined PROBE_DIR copy /y "%SystemRoot%\System32\winevt\Logs\Application.evtx" "%PROBE_DIR%micpe-application.evtx" >nul 2>&1
)
echo evtx_app=%EVTX_APP% >> "%PROBE_OUT%"
if exist "%PROBE_DIR%micpe-application.evtx" (echo evtx_app_copy=1 >> "%PROBE_OUT%") else (echo evtx_app_copy=0 >> "%PROBE_OUT%")
rem Crash dumps, if WerFault ever wrote one (run 41-45: werfault_end=0
rem every time, so these are expected 0 — the check is the evidence).
set "DUMP_MINIDUMP=0"
if exist "%SystemRoot%\Minidump\*.dmp" set "DUMP_MINIDUMP=1"
echo dump_minidump=%DUMP_MINIDUMP% >> "%PROBE_OUT%"
set "DUMP_CRASHDUMPS=0"
if exist "%SystemRoot%\System32\config\systemprofile\AppData\Local\CrashDumps\*.dmp" set "DUMP_CRASHDUMPS=1"
echo dump_crashdumps=%DUMP_CRASHDUMPS% >> "%PROBE_OUT%"
set "DUMP_MEMORY=0"
if exist "%SystemRoot%\MEMORY.dmp" set "DUMP_MEMORY=1"
echo dump_memory=%DUMP_MEMORY% >> "%PROBE_OUT%"

echo probe_done=1 >> "%PROBE_LOCAL%" & echo probe_done=1 >> "%PROBE_OUT%"

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
echo mark_uwp_enter=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_enter=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (
    echo explorer_guard=0 >> "%PROBE_LOCAL%" & echo explorer_guard=0 >> "%PROBE_OUT%"
    exit /b 1
)
rem Run 44410311576: explorer was Not Responding in the first two
rem snapshots and gone by the end snapshot, so it hung and then died
rem inside the run (death window 22:50:16-22:50:46 in run 41: alive at
rem the Photos guard, gone at the Media guard). The guard key says
rem which launch found it missing, and the PID says whether a later
rem launch sees the same process or a restarted one. ctfmon/ChsIME/
rem WmiPrvSE were already in the FIRST snapshot in run 41 (eval card
rem §27.5 said "first in the end snapshot" — wrong), so their late
rem appearance is not evidence about the death.
echo explorer_guard=1 >> "%PROBE_LOCAL%" & echo explorer_guard=1 >> "%PROBE_OUT%"
set "EXPLORER_PID="
for /f "tokens=2" %%P in ('tasklist /fi "imagename eq explorer.exe" /nh 2^>nul ^| find /i "explorer.exe"') do set "EXPLORER_PID=%%P"
if defined EXPLORER_PID (echo explorer_pid=%EXPLORER_PID% >> "%PROBE_LOCAL%" & echo explorer_pid=%EXPLORER_PID% >> "%PROBE_OUT%") else (echo explorer_pid=missing >> "%PROBE_LOCAL%" & echo explorer_pid=missing >> "%PROBE_OUT%")

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
echo mark_uwp_start_before=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_start_before=%TIME: =0% >> "%PROBE_OUT%"
start "" explorer.exe "%UWP_TARGET%"
echo mark_uwp_start_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_start_after=%TIME: =0% >> "%PROBE_OUT%"
set "UWP_WAIT=0"
:probe_uwp_poll
echo mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_wait_before=%TIME: =0% >> "%PROBE_OUT%"
choice /c Y /d Y /t 1 >nul
echo mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_wait_after=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq %UWP_PROC%.exe" /nh 2>nul | find /i "%UWP_PROC%.exe" >nul
if not errorlevel 1 exit /b 0
echo mark_uwp_poll_%UWP_PROC%_r%UWP_WAIT%_check_after=%TIME: =0% >> "%PROBE_OUT%"
rem Run 44428428849: in both death rounds explorer died ~25-30 s after a
rem start explorer.exe call (run 41: Photos start to Media guard; run 42:
rem Media start to after-media) — the same window as the poll itself, so
rem the after-check cannot tell whether the start killed it. Check
rem liveness once mid-poll (round 5) to split the death window in half:
rem alive at r5 and dead at the after-check means it died in the second
rem half of the poll, not at the start.
if %UWP_WAIT%==5 (
    tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
    if errorlevel 1 (echo explorer_midpoll_%UWP_PROC%=0 >> "%PROBE_LOCAL%" & echo explorer_midpoll_%UWP_PROC%=0 >> "%PROBE_OUT%") else (echo explorer_midpoll_%UWP_PROC%=1 >> "%PROBE_LOCAL%" & echo explorer_midpoll_%UWP_PROC%=1 >> "%PROBE_OUT%")
)
set /a UWP_WAIT+=1
if %UWP_WAIT% lss 10 goto :probe_uwp_poll
exit /b 1

:probe_xcheck
rem %1 = process image name, %2 = shell target. No explorer guard: this
rem is the cross-validation — the launch is attempted whether or not a
rem shell is alive. Returns errorlevel 0 when the process is running
rem after the attempt. The launch is a ShellExecute of the
rem shell:AppsFolder target (no explorer.exe in the command): on full
rem Windows this opens the app from cmd, and the parsing/activation
rem runs in-process. In PE with a dead shell it may fail outright; the
rem poll result (0/1) plus the frame-host check in the caller is the
rem evidence either way. Bounded poll, same shape as :probe_uwp
rem (choice, not ping; ten rounds, markers per round). The caller runs
rem the three calls inside DisableDelayedExpansion so the bang in the
rem AppUserModelId survives (U3); this subroutine itself uses %~2, so
rem it must be called with delayed expansion off.
echo mark_xcheck_enter=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_enter=%TIME: =0% >> "%PROBE_OUT%"
set "XCHECK_PROC=%~1"
set "XCHECK_TARGET=%~2"
tasklist /fi "imagename eq %XCHECK_PROC%.exe" /nh 2>nul | find /i "%XCHECK_PROC%.exe" >nul
if not errorlevel 1 exit /b 0
echo mark_xcheck_start_before=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_start_before=%TIME: =0% >> "%PROBE_OUT%"
rem Detached start (run 46 fix): a bare `start "" "shell:..."` for
rem an app that cannot activate BLOCKS the caller indefinitely —
rem CI run 44502105340 X1 sat in this start for 300 s with no
rem start_after (Server has no such app; the activation never
rem returns in a non-interactive session). So the ShellExecute
rem runs inside a child cmd: the outer start returns at once (cmd
rem is a real process), the child absorbs the block, and the probe
rem keeps polling — if the app ever appears the poll finds it, if
rem not the poll gives up after ten rounds and the probe completes.
rem The child cmd lingers while blocked; it is harmless in PE and
rem the runner is discarded after the job. The launch still does
rem not go through explorer.exe.
start "" cmd /c start "" "%XCHECK_TARGET%"
echo mark_xcheck_start_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_start_after=%TIME: =0% >> "%PROBE_OUT%"
set "XCHECK_WAIT=0"
:probe_xcheck_poll
echo mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_wait_before=%TIME: =0% >> "%PROBE_OUT%"
choice /c Y /d Y /t 1 >nul
echo mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_wait_after=%TIME: =0% >> "%PROBE_OUT%"
tasklist /fi "imagename eq %XCHECK_PROC%.exe" /nh 2>nul | find /i "%XCHECK_PROC%.exe" >nul
if not errorlevel 1 exit /b 0
echo mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_check_after=%TIME: =0% >> "%PROBE_OUT%"
set /a XCHECK_WAIT+=1
if %XCHECK_WAIT% lss 10 goto :probe_xcheck_poll
exit /b 1

:probe_explorer_cpu
rem %1 = key suffix: shell, preuwp, calculator, photos, media, end
rem (run 44428428849). Records explorer's CPU time at this point in the
rem run, so the segments can be compared: a time that never advances
rem means the process stopped doing work. tasklist /v /fo list prints
rem one CPU-time line per process ("CPU Time:  0:00:13" in en-US,
rem "CPU 时间:  0:00:13" in zh-CN); tokens=3 is the time itself (the
rem table form cannot be parsed — its memory column holds "31,048 K",
rem whose comma breaks token counting). The match is on "CPU" alone,
rem not "CPU Time": run 44459251306 proved the zh-CN image prints
rem "CPU 时间" (tasklist file header bytes CPU \xca\xb1\xbc\xe4), so
rem "CPU Time" never matches there and every key came back missing.
rem "CPU" is safe as the match: it is the first token of that line in
rem both languages, and no other list-form line contains it. No /nh:
rem it is only valid with /fo table or csv (Microsoft docs), and with
rem /fo list it makes tasklist fail — the error was swallowed by 2>nul,
rem so every key came back missing in run 44441708839. The list form
rem has no column headers to suppress. Missing when the process is gone
rem or the line never appears. The for /f runs in a child cmd, so a
rem missing tasklist there cannot kill this batch; in the image
rem tasklist is shipped (10-cmdpe.txt).
set "EXPLORER_CPU="
for /f "tokens=3" %%C in ('tasklist /v /fo list /fi "imagename eq explorer.exe" 2^>nul ^| find /i "CPU"') do set "EXPLORER_CPU=%%C"
if defined EXPLORER_CPU (echo explorer_cpu_%~1=%EXPLORER_CPU% >> "%PROBE_LOCAL%" & echo explorer_cpu_%~1=%EXPLORER_CPU% >> "%PROBE_OUT%") else (echo explorer_cpu_%~1=missing >> "%PROBE_LOCAL%" & echo explorer_cpu_%~1=missing >> "%PROBE_OUT%")
exit /b 0

:probe_svc
rem %1 = service name, %2 = probe key (run 44349189039), %3 = local
rem mirror file (optional, run 44428428849: the serial diagnostics
rem need the service states in the local file too).
rem Writes <key>=RUNNING, STOPPED or MISSING. sc query returns 0 when
rem the service exists (even stopped) and 1060 when it does not.
sc query "%~1" >nul 2>&1
if errorlevel 1 (
    echo %~2=MISSING >> "%PROBE_OUT%"
    if not "%~3"=="" echo %~2=MISSING >> "%~3"
    exit /b 0
)
sc query "%~1" 2>nul | find /i "RUNNING" >nul
if not errorlevel 1 (
    echo %~2=RUNNING >> "%PROBE_OUT%"
    if not "%~3"=="" echo %~2=RUNNING >> "%~3"
) else (
    echo %~2=STOPPED >> "%PROBE_OUT%"
    if not "%~3"=="" echo %~2=STOPPED >> "%~3"
)
exit /b 0
