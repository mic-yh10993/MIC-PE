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
rem Run 48: A: and B: are in the scan now — run 47 proved the mirror
rem volume mounts as A: and the old C-first scan never saw it, so
rem mirror=0 was a probe miss, not a missing volume.
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
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
rem Run 48: A: and B: are enumerated too — run 47 mounted the mirror
rem as A: and the old list hid it from drives= as well as from the
rem sentinel scan, so both keys blamed the volume instead of the scan.
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist "%%D:\" set "DRIVES=!DRIVES!%%D"
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
rem Run 49 (BEX64 breakpoint control): the folder-window creation is
rem SKIPPED this round — run 48 died at 14:27, one minute after the
rem folder-window test at 14:26:39, inside the same diag/uwp-opening
rem window, so the creation itself is the prime suspect for the
rem c0000409 stack overrun. If explorer still dies in the same window
rem without it, the trigger is shell self-init; if it lives past diag,
rem the trigger is the folder-window creation. Set the flag to 1 to
rem restore the test. The tasklist snapshots below are read-only and
rem stay: they say what explorer loaded (or that it is already gone).
set "FOLDER_WINDOW_TEST=0"
echo mark_folder_window=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_folder_window=%TIME: =0% >> "%PROBE_OUT%"
if "%FOLDER_WINDOW_TEST%"=="1" (
    start "" explorer.exe "%SystemDrive%\"
    choice /c Y /d Y /t 3 >nul
    echo folder_window_test=1 >> "%PROBE_OUT%"
) else (
    echo folder_window_test=0 >> "%PROBE_OUT%"
    echo folder_window_skipped=1 >> "%PROBE_LOCAL%" & echo folder_window_skipped=1 >> "%PROBE_OUT%"
)
echo --- tasklist after folder-window test --- >> "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>nul
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
rem Run 48: the exit codes are dual-written now — they are verdict keys
rem for the activation chain, and run 47 proved a share-only key can
rem go missing when the host view stalls. AppReadiness gets the same
rem read: its exit code was never recorded before.
if defined APPXSVC_EXIT (echo appxsvc_exitcode=%APPXSVC_EXIT% >> "%PROBE_LOCAL%" & echo appxsvc_exitcode=%APPXSVC_EXIT% >> "%PROBE_OUT%") else (echo appxsvc_exitcode=missing >> "%PROBE_LOCAL%" & echo appxsvc_exitcode=missing >> "%PROBE_OUT%")
set "STATEREPO_EXIT="
for /f "tokens=3" %%A in ('sc queryex StateRepository 2^>nul ^| find /i "WIN32_EXIT_CODE"') do set "STATEREPO_EXIT=%%A"
if defined STATEREPO_EXIT (echo staterepo_exitcode=%STATEREPO_EXIT% >> "%PROBE_LOCAL%" & echo staterepo_exitcode=%STATEREPO_EXIT% >> "%PROBE_OUT%") else (echo staterepo_exitcode=missing >> "%PROBE_LOCAL%" & echo staterepo_exitcode=missing >> "%PROBE_OUT%")
set "APPREADY_EXIT="
for /f "tokens=3" %%A in ('sc queryex AppReadiness 2^>nul ^| find /i "WIN32_EXIT_CODE"') do set "APPREADY_EXIT=%%A"
if defined APPREADY_EXIT (echo appready_exitcode=%APPREADY_EXIT% >> "%PROBE_LOCAL%" & echo appready_exitcode=%APPREADY_EXIT% >> "%PROBE_OUT%") else (echo appready_exitcode=missing >> "%PROBE_LOCAL%" & echo appready_exitcode=missing >> "%PROBE_OUT%")
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
if "%APPXSTORE_CALC%"=="0" (echo appxstore_calc=1 >> "%PROBE_LOCAL%" & echo appxstore_calc=1 >> "%PROBE_OUT%") else (echo appxstore_calc=0 >> "%PROBE_LOCAL%" & echo appxstore_calc=0 >> "%PROBE_OUT%")
echo mark_appxstore_photos_query=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_photos_query=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.Photos" >nul
set "APPXSTORE_PHOTOS=%ERRORLEVEL%"
echo mark_appxstore_photos_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_photos_after=%TIME: =0% >> "%PROBE_OUT%"
if "%APPXSTORE_PHOTOS%"=="0" (echo appxstore_photos=1 >> "%PROBE_LOCAL%" & echo appxstore_photos=1 >> "%PROBE_OUT%") else (echo appxstore_photos=0 >> "%PROBE_LOCAL%" & echo appxstore_photos=0 >> "%PROBE_OUT%")
echo mark_appxstore_media_query=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_media_query=%TIME: =0% >> "%PROBE_OUT%"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.ZuneMusic" >nul
set "APPXSTORE_MEDIA=%ERRORLEVEL%"
echo mark_appxstore_media_after=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_appxstore_media_after=%TIME: =0% >> "%PROBE_OUT%"
if "%APPXSTORE_MEDIA%"=="0" (echo appxstore_media=1 >> "%PROBE_LOCAL%" & echo appxstore_media=1 >> "%PROBE_OUT%") else (echo appxstore_media=0 >> "%PROBE_LOCAL%" & echo appxstore_media=0 >> "%PROBE_OUT%")
rem Run 45 (UWP frame host): the two SystemApps hosts are registered in
rem AppxAllUserStore\InboxApplications by the SOFTWARE hive swap
rem (Install-ExplorerShell), not by a build-time write — these queries
rem confirm the swap carried them. No mark_ markers: the three queries
rem above already proved this pattern does not hang.
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.ShellExperienceHost" >nul
set "APPXSTORE_SEH=%ERRORLEVEL%"
if "%APPXSTORE_SEH%"=="0" (echo appxstore_shellexperiencehost=1 >> "%PROBE_LOCAL%" & echo appxstore_shellexperiencehost=1 >> "%PROBE_OUT%") else (echo appxstore_shellexperiencehost=0 >> "%PROBE_LOCAL%" & echo appxstore_shellexperiencehost=0 >> "%PROBE_OUT%")
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s 2>nul | find /i "Microsoft.Windows.StartMenuExperienceHost" >nul
set "APPXSTORE_SMEH=%ERRORLEVEL%"
if "%APPXSTORE_SMEH%"=="0" (echo appxstore_startmenuexperiencehost=1 >> "%PROBE_LOCAL%" & echo appxstore_startmenuexperiencehost=1 >> "%PROBE_OUT%") else (echo appxstore_startmenuexperiencehost=0 >> "%PROBE_LOCAL%" & echo appxstore_startmenuexperiencehost=0 >> "%PROBE_OUT%")
rem Run 46 (explorer breakpoint, §31.9 #3): in run 45 explorer died
rem during the diagnostics — last alive evidence the second tasklist
rem snapshot, first dead evidence the Calculator guard — so the death
rem window spans the whole appxstore/host-query stretch. Check liveness
rem once mid-diagnosis (plus a CPU sample) to split that window at the
rem queries instead of spanning the section.
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_mid_diag=0 >> "%PROBE_OUT%") else (echo explorer_mid_diag=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu diag


rem Run 47 (explorer breakpoint, §32.12 #1): the run-46 WER/evtx/dump
rem capture lived in the end snapshot, so the guest wedging in the
rem Media poll took all of it — the breakpoint evidence stayed blank.
rem Take the same snapshot here, in the diagnostics, so the evidence
rem survives even if the probe dies in the launches. The end snapshot
rem keeps its own unsuffixed copy; these early ones carry the suffix.
call :probe_wer_snapshot diag
call :probe_sync_local

rem --- uwp -------------------------------------------------------------------
echo mark_uwp_appx=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_appx=%TIME: =0% >> "%PROBE_OUT%"
if exist "%SystemRoot%\System32\AppXDeploymentClient.dll" (
    echo uwp_appx=1 >> "%PROBE_OUT%"
) else (
    echo uwp_appx=0 >> "%PROBE_OUT%"
)

rem --- activation (run 47) ---------------------------------------------------
rem Sits in the uwp section opening, right after the appx check and
rem still before any launch — NOT in the diagnostics above: the
rem activation_files line names AppXDeploymentClient.dll, and a
rem marker test pins mark_uwp_appx before the first occurrence of
rem that name, so the check cannot sit above the marker.
rem Run 46: the package is in the store (appxstore_media=1) but the
rem shell namespace cannot resolve its AUMID — Media's launch died
rem with a "Windows cannot find the file" dialog. These checks say
rem which link of the activation chain is broken, before the launches:
rem the shell:AppsFolder class registration, the per-app AUMID entries
rem in AppxAllUserStore (a package entry without its Applications
rem subkey cannot resolve), the activation DLLs, the deployment
rem services' config, and the volume table (mountvol lists volumes
rem even without a drive letter — the mirror volume question from
rem run 46: QEMU attached it, the guest never lettered it).
rem The AUMID lookups run with delayed expansion off (the bang in the
rem AppUserModelId would be stripped otherwise, U3); the result is
rem echoed inside the block so endlocal cannot lose it.
reg query "HKLM\SOFTWARE\Classes\CLSID\{4234d49b-0245-4df3-b780-3893943456e1}" >nul 2>&1
if errorlevel 1 (echo appsfolder_clsid=0 >> "%PROBE_LOCAL%" & echo appsfolder_clsid=0 >> "%PROBE_OUT%") else (echo appsfolder_clsid=1 >> "%PROBE_LOCAL%" & echo appsfolder_clsid=1 >> "%PROBE_OUT%")
setlocal DisableDelayedExpansion
rem Dump the store once, then search the file: the AUMID carries a
rem bang, and a piped `find "...!App"` dies in the pipe child (CI
rem run 44519361912: the batch died on the reg-query line with exit
rem 255 and no stderr — the pipe child parses the bang with delayed
rem expansion on, and the unterminated !...! swallows the rest of
rem the batch looking for its closing bang). A file search keeps the
rem bang in the parent, where delayed expansion is off; one dump
rem also replaces three full-store enumerations.
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s > "%SystemDrive%\micpe-aumid.tmp" 2>nul
find /i "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App" "%SystemDrive%\micpe-aumid.tmp" >nul
set "AUMID_CALC=%ERRORLEVEL%"
if "%AUMID_CALC%"=="0" (echo aumid_calc=1 >> "%PROBE_LOCAL%" & echo aumid_calc=1 >> "%PROBE_OUT%") else (echo aumid_calc=0 >> "%PROBE_LOCAL%" & echo aumid_calc=0 >> "%PROBE_OUT%")
find /i "Microsoft.Windows.Photos_8wekyb3d8bbwe!App" "%SystemDrive%\micpe-aumid.tmp" >nul
set "AUMID_PHOTOS=%ERRORLEVEL%"
if "%AUMID_PHOTOS%"=="0" (echo aumid_photos=1 >> "%PROBE_LOCAL%" & echo aumid_photos=1 >> "%PROBE_OUT%") else (echo aumid_photos=0 >> "%PROBE_LOCAL%" & echo aumid_photos=0 >> "%PROBE_OUT%")
find /i "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic" "%SystemDrive%\micpe-aumid.tmp" >nul
set "AUMID_MEDIA=%ERRORLEVEL%"
if "%AUMID_MEDIA%"=="0" (echo aumid_media=1 >> "%PROBE_LOCAL%" & echo aumid_media=1 >> "%PROBE_OUT%") else (echo aumid_media=0 >> "%PROBE_LOCAL%" & echo aumid_media=0 >> "%PROBE_OUT%")
rem Run 48: the dump's line count says whether the store enumeration
rem itself was empty — appxstore_*=1 proves the package keys exist,
rem so aumid_*=0 with a rich dump means the !App subkeys are missing,
rem while a near-empty dump would blame the enumeration instead.
set "AUMID_LINES=0"
if exist "%SystemDrive%\micpe-aumid.tmp" for /f %%A in (%SystemDrive%\micpe-aumid.tmp) do set /a AUMID_LINES+=1
echo aumid_lines=%AUMID_LINES% >> "%PROBE_LOCAL%" & echo aumid_lines=%AUMID_LINES% >> "%PROBE_OUT%"
del "%SystemDrive%\micpe-aumid.tmp" >nul 2>&1
endlocal
if exist "%SystemRoot%\System32\twinapi.appcore.dll" if exist "%SystemRoot%\System32\Windows.UI.Xaml.dll" if exist "%SystemRoot%\System32\AppXDeploymentClient.dll" if exist "%SystemRoot%\System32\Windows.StateRepository.dll" (echo activation_files=1 >> "%PROBE_LOCAL%" & echo activation_files=1 >> "%PROBE_OUT%") else (echo activation_files=0 >> "%PROBE_LOCAL%" & echo activation_files=0 >> "%PROBE_OUT%")
rem Run 48: AppXDeploymentServer.dll is the in-process deployment
rem server the activation path loads (the client DLL above is only
rem the caller side) — its absence would break activation even with
rem the client present.
if exist "%SystemRoot%\System32\AppXDeploymentServer.dll" (echo activation_appxdeployserver=1 >> "%PROBE_LOCAL%" & echo activation_appxdeployserver=1 >> "%PROBE_OUT%") else (echo activation_appxdeployserver=0 >> "%PROBE_LOCAL%" & echo activation_appxdeployserver=0 >> "%PROBE_OUT%")
echo --- sc qc AppXSVC --- >> "%TASKLIST_OUT%"
sc qc AppXSVC >> "%TASKLIST_OUT%" 2>&1
echo --- sc qc StateRepository --- >> "%TASKLIST_OUT%"
sc qc StateRepository >> "%TASKLIST_OUT%" 2>&1
echo --- sc qc AppReadiness --- >> "%TASKLIST_OUT%"
sc qc AppReadiness >> "%TASKLIST_OUT%" 2>&1
rem Run 48: the raw sc qc dumps above name the config, but the stage
rem cannot assert on a tasklist dump — record the parsed values as
rem keys: the Start type (3 = manual, so nothing ever starts the
rem service unless asked), the ServiceDll the SCM would load, whether
rem that file exists, and the account it would run as. Together with
rem the queryex exit codes above, these say WHY a deployment service
rem never runs. Reads only — the run 39 control (no sc start in this
rem probe) stays in force; starting the services is a separate
rem experiment, not this round.
call :probe_svc_reg AppXSVC appxsvc
call :probe_svc_reg StateRepository staterepo
call :probe_svc_reg AppReadiness appready
rem Run 50 (feature 42537950 source investigation): the image's offline
rem SYSTEM hive holds 330 FeatureManagement Overrides (groups 0/15/9)
rem and none of them is 42537950 — DisableWin10Taskbar runs at its
rem built-in default (enabled), and CTray::Init failfasts on it
rem (run 49, tray.cpp:595, 0x1181ea). The CI build now imports an
rem override forcing it off (70-feature-42537950.reg, EnabledState=0).
rem Read it back here, read-only, so the stage can say whether the
rem import landed in the running image — and whether the override is
rem really off before any UWP launch is attempted. The three group
rem checks say whether the feature also sits in a group override
rem (it does not in the image; a 1 here would mean the image changed).
rem The EnabledState line reads "EnabledState    REG_DWORD    0x0", so
rem tokens=3 yields the hex value; a missing key leaves missing.
rem Run 51: the flat entry run 50 wrote was ignored by the loader
rem (§36.5.1 — it reads grouped entries only), so the patch now
rem writes all three groups and the flat entry is gone. The flat
rem read-back below stays as a control (expect missing now); the
rem three group keys are the asserted ones. No new mark_ marker:
rem this section rides under mark_uwp_svc, and the marker count (39)
rem stays put.
set "FM_STATE=missing"
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\42537950" /v EnabledState 2^>nul ^| find /i "EnabledState"') do set "FM_STATE=%%A"
echo fm_42537950_state=%FM_STATE% >> "%PROBE_LOCAL%" & echo fm_42537950_state=%FM_STATE% >> "%PROBE_OUT%"
set "FM_G0=missing"
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\0\42537950" /v EnabledState 2^>nul ^| find /i "EnabledState"') do set "FM_G0=%%A"
echo fm_42537950_group0=%FM_G0% >> "%PROBE_LOCAL%" & echo fm_42537950_group0=%FM_G0% >> "%PROBE_OUT%"
set "FM_G15=missing"
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\15\42537950" /v EnabledState 2^>nul ^| find /i "EnabledState"') do set "FM_G15=%%A"
echo fm_42537950_group15=%FM_G15% >> "%PROBE_LOCAL%" & echo fm_42537950_group15=%FM_G15% >> "%PROBE_OUT%"
set "FM_G9=missing"
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\9\42537950" /v EnabledState 2^>nul ^| find /i "EnabledState"') do set "FM_G9=%%A"
echo fm_42537950_group9=%FM_G9% >> "%PROBE_LOCAL%" & echo fm_42537950_group9=%FM_G9% >> "%PROBE_OUT%"
rem Run 50 (minidump route re-check): 60-werdumps.reg pointed its key
rem at HKLM\SOFTWARE, which a plain reg.exe import writes into the
rem RUNNER's live hive — the image hives are mounted as PE-SOFT/PE-SYS,
rem so run 49's image never got the LocalDumps key (dump_* all 0).
rem The file now addresses PE-SOFT; read the key back here to prove it
rem landed in the running image. A missing here means the LocalDumps
rem route is still unproven, not that WER is broken.
set "WER_DUMPS=missing"
for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\explorer.exe" /v DumpFolder 2^>nul ^| find /i "DumpFolder"') do set "WER_DUMPS=%%A"
echo wer_localdumps_folder=%WER_DUMPS% >> "%PROBE_LOCAL%" & echo wer_localdumps_folder=%WER_DUMPS% >> "%PROBE_OUT%"
rem Run 50 (StateRepository why-not-started): its only dependency is
rem RpcSs and its svchost group appmodel is defined in the image
rem (SOFTWARE hive: appmodel = EntAppSvc, StateRepository, WalletService),
rem so neither a missing group nor a missing dependency explains the
rem STOPPED state. Record RpcSs's own state and the group definition
rem in the running image; the sc start experiment itself stays in a
rem later round, after probe_done (eval card §34.7).
call :probe_svc RpcSs rpcss "%PROBE_LOCAL%"
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" /v appmodel >nul 2>&1
if errorlevel 1 (echo svchost_appmodel=0 >> "%PROBE_LOCAL%" & echo svchost_appmodel=0 >> "%PROBE_OUT%") else (echo svchost_appmodel=1 >> "%PROBE_LOCAL%" & echo svchost_appmodel=1 >> "%PROBE_OUT%")
echo --- mountvol --- >> "%TASKLIST_OUT%"
mountvol >> "%TASKLIST_OUT%" 2>nul
echo mountvol_dump=1 >> "%PROBE_LOCAL%" & echo mountvol_dump=1 >> "%PROBE_OUT%"
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
if exist "%SystemRoot%\System32\ApplicationFrameHost.exe" if exist "%SystemRoot%\System32\RuntimeBroker.exe" if exist "%SystemRoot%\SystemApps\ShellExperienceHost_cw5n1h2txyewy\ShellExperienceHost.exe" if exist "%SystemRoot%\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\StartMenuExperienceHost.exe" (echo framehost_files=1 >> "%PROBE_LOCAL%" & echo framehost_files=1 >> "%PROBE_OUT%") else (echo framehost_files=0 >> "%PROBE_LOCAL%" & echo framehost_files=0 >> "%PROBE_OUT%")
if exist "%SystemRoot%\System32\Windows.StateRepository.dll" if exist "%SystemRoot%\System32\AppReadiness.dll" (echo framehost_dlls=1 >> "%PROBE_LOCAL%" & echo framehost_dlls=1 >> "%PROBE_OUT%") else (echo framehost_dlls=0 >> "%PROBE_LOCAL%" & echo framehost_dlls=0 >> "%PROBE_OUT%")

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
if errorlevel 1 (echo uwp_launch_calculator=0 >> "%PROBE_LOCAL%" & echo uwp_launch_calculator=0 >> "%PROBE_OUT%") else (echo uwp_launch_calculator=1 >> "%PROBE_LOCAL%" & echo uwp_launch_calculator=1 >> "%PROBE_OUT%")
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
if errorlevel 1 (echo uwp_launch_photos=0 >> "%PROBE_LOCAL%" & echo uwp_launch_photos=0 >> "%PROBE_OUT%") else (echo uwp_launch_photos=1 >> "%PROBE_LOCAL%" & echo uwp_launch_photos=1 >> "%PROBE_OUT%")
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_after_photos=0 >> "%PROBE_LOCAL%" & echo explorer_after_photos=0 >> "%PROBE_OUT%") else (echo explorer_after_photos=1 >> "%PROBE_LOCAL%" & echo explorer_after_photos=1 >> "%PROBE_OUT%")
call :probe_explorer_cpu photos

echo mark_uwp_launch_media=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_uwp_launch_media=%TIME: =0% >> "%PROBE_OUT%"
call :probe_uwp Microsoft.Media.Player "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
if errorlevel 1 (echo uwp_launch_media=0 >> "%PROBE_LOCAL%" & echo uwp_launch_media=0 >> "%PROBE_OUT%") else (echo uwp_launch_media=1 >> "%PROBE_LOCAL%" & echo uwp_launch_media=1 >> "%PROBE_OUT%")
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

rem Run 47: second WER/evtx snapshot, after the launches — an
rem explorer death in the UWP section leaves its report here even if
rem the probe wedges in the cross-check below.
call :probe_wer_snapshot uwp
call :probe_sync_local

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
if errorlevel 1 (echo xcheck_explorer_before=0 >> "%PROBE_LOCAL%" & echo xcheck_explorer_before=0 >> "%PROBE_OUT%") else (echo xcheck_explorer_before=1 >> "%PROBE_LOCAL%" & echo xcheck_explorer_before=1 >> "%PROBE_OUT%")
setlocal DisableDelayedExpansion
echo mark_xcheck_launch_calculator=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_launch_calculator=%TIME: =0% >> "%PROBE_OUT%"
call :probe_xcheck CalculatorApp "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
if errorlevel 1 (echo xcheck_launch_calculator=0 >> "%PROBE_LOCAL%" & echo xcheck_launch_calculator=0 >> "%PROBE_OUT%") else (echo xcheck_launch_calculator=1 >> "%PROBE_LOCAL%" & echo xcheck_launch_calculator=1 >> "%PROBE_OUT%")
echo mark_xcheck_launch_photos=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_launch_photos=%TIME: =0% >> "%PROBE_OUT%"
call :probe_xcheck Microsoft.Lightbox "shell:AppsFolder\Microsoft.Windows.Photos_8wekyb3d8bbwe!App"
if errorlevel 1 (echo xcheck_launch_photos=0 >> "%PROBE_LOCAL%" & echo xcheck_launch_photos=0 >> "%PROBE_OUT%") else (echo xcheck_launch_photos=1 >> "%PROBE_LOCAL%" & echo xcheck_launch_photos=1 >> "%PROBE_OUT%")
echo mark_xcheck_launch_media=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_xcheck_launch_media=%TIME: =0% >> "%PROBE_OUT%"
call :probe_xcheck Microsoft.Media.Player "shell:AppsFolder\Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
if errorlevel 1 (echo xcheck_launch_media=0 >> "%PROBE_LOCAL%" & echo xcheck_launch_media=0 >> "%PROBE_OUT%") else (echo xcheck_launch_media=1 >> "%PROBE_LOCAL%" & echo xcheck_launch_media=1 >> "%PROBE_OUT%")
endlocal
"%SystemRoot%\System32\tasklist.exe" /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo xcheck_explorer_after=0 >> "%PROBE_LOCAL%" & echo xcheck_explorer_after=0 >> "%PROBE_OUT%") else (echo xcheck_explorer_after=1 >> "%PROBE_LOCAL%" & echo xcheck_explorer_after=1 >> "%PROBE_OUT%")
"%SystemRoot%\System32\tasklist.exe" /fi "imagename eq ApplicationFrameHost.exe" /nh 2>nul | find /i "ApplicationFrameHost.exe" >nul
if errorlevel 1 (echo xcheck_framehost_after=0 >> "%PROBE_LOCAL%" & echo xcheck_framehost_after=0 >> "%PROBE_OUT%") else (echo xcheck_framehost_after=1 >> "%PROBE_LOCAL%" & echo xcheck_framehost_after=1 >> "%PROBE_OUT%")

rem Run 47: third WER/evtx snapshot, after the cross-check — the last
rem breakpoint evidence before the payload/brand/installer stretch.
call :probe_wer_snapshot xcheck
call :probe_sync_local

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
echo payload=%PAYLOAD% >> "%PROBE_LOCAL%" & echo payload=%PAYLOAD% >> "%PROBE_OUT%"

rem --- brand ----------------------------------------------------------------
echo mark_brand=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_brand=%TIME: =0% >> "%PROBE_OUT%"
set "BRAND=1"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Manufacturer 2>nul | find /i "MICPE" >nul
if errorlevel 1 set "BRAND=0"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v SupportURL 2>nul | find /i "space.bilibili.com/1978487514" >nul
if errorlevel 1 set "BRAND=0"
if not exist "%SystemRoot%\System32\oemlogo.bmp" set "BRAND=0"
echo brand=%BRAND% >> "%PROBE_LOCAL%" & echo brand=%BRAND% >> "%PROBE_OUT%"
call :probe_sync_local

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
    echo installer_scan=0 >> "%PROBE_LOCAL%" & echo installer_scan=0 >> "%PROBE_OUT%"
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
if exist "%DEPLOY_TARGET%:\EFI\Microsoft\Boot\BCD" echo installer_boot=1 >> "%PROBE_LOCAL%" & echo installer_boot=1 >> "%PROBE_OUT%"
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
rem Run 50 (feature 42537950 fix outcome): the m5 stage asserts
rem explorer_end=1 — explorer must still be alive at probe end, not
rem just at the shell check (the old explorer=1 is set while it is
rem still starting). Same tasklist /fi shape as werfault_end/dwm_end.
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer_end=0 >> "%PROBE_LOCAL%" & echo explorer_end=0 >> "%PROBE_OUT%") else (echo explorer_end=1 >> "%PROBE_LOCAL%" & echo explorer_end=1 >> "%PROBE_OUT%")
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
        rem Run 48: direct copy to the share, same reason as the
        rem mid-run snapshots — the tasklist transcription did not
        rem survive run 47. This is the unsuffixed end-snapshot copy.
        if defined PROBE_DIR copy /y "%%D\Report.wer" "%PROBE_DIR%micpe-wer-explorer.wer" >nul 2>&1
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
if defined PROBE_DIR if exist "%PROBE_DIR%micpe-wer-explorer.wer" (echo wer_wer_copy=1 >> "%PROBE_LOCAL%" & echo wer_wer_copy=1 >> "%PROBE_OUT%") else (echo wer_wer_copy=0 >> "%PROBE_LOCAL%" & echo wer_wer_copy=0 >> "%PROBE_OUT%")
echo wer_explorer=%WER_EXPLORER% >> "%PROBE_LOCAL%" & echo wer_explorer=%WER_EXPLORER% >> "%PROBE_OUT%"
rem Run 49: the end snapshot's dump files, same copy as the mid-run
rem snapshots — a wedge after this point must not take them.
call :probe_dump_copy end

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

rem Run 49 (mirror late enumeration): run 48's mirror=0 was NOT a scan
rem miss — the scan already covered A: — the volume simply had not
rem enumerated when the probe started. Re-scan here, at the end of the
rem run, so a late-enumerating volume is caught; the _late keys say
rem what the guest sees when the probe finishes. The mountvol dump
rem goes into the same tasklist file for a human cross-check.
echo mark_mirror_late=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_mirror_late=%TIME: =0% >> "%PROBE_OUT%"
set "MIRROR_LATE="
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\micpe-mirror.txt" set "MIRROR_LATE=%%D:\"
)
if defined MIRROR_LATE (echo mirror_late=1 >> "%PROBE_LOCAL%" & echo mirror_late=1 >> "%PROBE_OUT%") else (echo mirror_late=0 >> "%PROBE_LOCAL%" & echo mirror_late=0 >> "%PROBE_OUT%")
if defined MIRROR_LATE (echo mirror_drive_late=%MIRROR_LATE% >> "%PROBE_LOCAL%" & echo mirror_drive_late=%MIRROR_LATE% >> "%PROBE_OUT%")
set "DRIVES_LATE="
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist "%%D:\" set "DRIVES_LATE=!DRIVES_LATE!%%D"
echo drives_late=%DRIVES_LATE% >> "%PROBE_LOCAL%" & echo drives_late=%DRIVES_LATE% >> "%PROBE_OUT%"
echo --- mountvol (end) --- >> "%TASKLIST_OUT%"
mountvol >> "%TASKLIST_OUT%" 2>nul
echo mountvol_end=1 >> "%PROBE_LOCAL%" & echo mountvol_end=1 >> "%PROBE_OUT%"

rem Run 48: probe_done goes to the local file FIRST, then the share
rem copy is refreshed by a detached copy — never by a share append.
rem Run 47 died between the end snapshot and shutdown, most likely on
rem the share append of this very line, and the host then waited out
rem the full timeout for a line the guest had already written. The
rem copy is the channel that survived run 47 (the local copy reached
rem the host complete at every section sync); the detached copy plus
rem a fixed 3-second wait means a wedged share write can delay the
rem copy but can no longer stop the shutdown that flushes the share.
rem The watchdog and the harness both read the share copy, so a copy
rem that lands in under 3 seconds still ends the wait the fast way.
echo probe_done=1 >> "%PROBE_LOCAL%"
if defined PROBE_DIR start "" /min cmd /c copy /y "%PROBE_LOCAL%" "%PROBE_DIR%micpe-probe-local.txt" >nul 2>&1
choice /c Y /d Y /t 3 >nul

rem Run 51 (service start experiment, eval card §34.7): probe_done is
rem already in the LOCAL file and the share copy is detached, so
rem whatever happens here cannot lose a conclusion — the worst case
rem is a delayed shutdown. RpcSs is StateRepository's only dependency
rem and it is STOPPED in PE (run 50), so try starting it and watch
rem whether StateRepository follows and whether AUMID becomes
rem resolvable. The start itself runs detached with a bounded wait
rem (run 39: two start calls stalled probe + watchdog within ~15s)
rem — the parent never blocks on the start command, and a hung start
rem is taskkilled. StateRepository and AppXSVC get the same treatment
rem after RpcSs, then the AUMID store is dumped again.
call :probe_sc_start RpcSs rpcss
call :probe_svc RpcSs rpcss_after_start "%PROBE_LOCAL%"
call :probe_svc StateRepository staterepo_after_rpcss "%PROBE_LOCAL%"
call :probe_sc_start StateRepository staterepo
call :probe_svc StateRepository staterepo_after_start "%PROBE_LOCAL%"
call :probe_sc_start AppXSVC appxsvc
call :probe_svc AppXSVC appxsvc_after_start "%PROBE_LOCAL%"
rem AUMID re-dump: same store query as the cross-check section, with
rem _after keys — if StateRepository came up, the !App subkeys may
rem resolve now. Dump to a file and search the file (never a pipe:
rem CI run 44519361912 — a piped find with a bang kills the batch).
setlocal DisableDelayedExpansion
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore" /s > "%SystemDrive%\micpe-aumid-after.tmp" 2>nul
find /i "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App" "%SystemDrive%\micpe-aumid-after.tmp" >nul
set "AUMID_AFTER_CALC=%ERRORLEVEL%"
if "%AUMID_AFTER_CALC%"=="0" (echo aumid_after_calc=1 >> "%PROBE_LOCAL%" & echo aumid_after_calc=1 >> "%PROBE_OUT%") else (echo aumid_after_calc=0 >> "%PROBE_LOCAL%" & echo aumid_after_calc=0 >> "%PROBE_OUT%")
find /i "Microsoft.Windows.Photos_8wekyb3d8bbwe!App" "%SystemDrive%\micpe-aumid-after.tmp" >nul
set "AUMID_AFTER_PHOTOS=%ERRORLEVEL%"
if "%AUMID_AFTER_PHOTOS%"=="0" (echo aumid_after_photos=1 >> "%PROBE_LOCAL%" & echo aumid_after_photos=1 >> "%PROBE_OUT%") else (echo aumid_after_photos=0 >> "%PROBE_LOCAL%" & echo aumid_after_photos=0 >> "%PROBE_OUT%")
find /i "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic" "%SystemDrive%\micpe-aumid-after.tmp" >nul
set "AUMID_AFTER_MEDIA=%ERRORLEVEL%"
if "%AUMID_AFTER_MEDIA%"=="0" (echo aumid_after_media=1 >> "%PROBE_LOCAL%" & echo aumid_after_media=1 >> "%PROBE_OUT%") else (echo aumid_after_media=0 >> "%PROBE_LOCAL%" & echo aumid_after_media=0 >> "%PROBE_OUT%")
set "AUMID_AFTER_LINES=0"
if exist "%SystemDrive%\micpe-aumid-after.tmp" for /f %%A in (%SystemDrive%\micpe-aumid-after.tmp) do set /a AUMID_AFTER_LINES+=1
echo aumid_after_lines=%AUMID_AFTER_LINES% >> "%PROBE_LOCAL%" & echo aumid_after_lines=%AUMID_AFTER_LINES% >> "%PROBE_OUT%"
del "%SystemDrive%\micpe-aumid-after.tmp" >nul 2>&1
endlocal
rem Fifth sync: the experiment wrote keys after the detached end copy
rem fired, so copy the local file to the share once more — otherwise
rem the experiment keys live only in the share probe file, whose host
rem view stalled after xcheck in run 50.
call :probe_sync_local

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

call :probe_poll_check %UWP_PROC%
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
call :probe_poll_check %UWP_PROC%
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
    call :probe_poll_check explorer
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
call :probe_poll_check %XCHECK_PROC%
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
call :probe_poll_check %XCHECK_PROC%
if not errorlevel 1 exit /b 0
echo mark_xcheck_poll_%XCHECK_PROC%_r%XCHECK_WAIT%_check_after=%TIME: =0% >> "%PROBE_OUT%"
rem Run 47: same mid-poll liveness split as :probe_uwp_poll — if the
rem cross-check launch kills the shell, r5 says which half it died in.
if %XCHECK_WAIT%==5 (
    call :probe_poll_check explorer
    if errorlevel 1 (echo explorer_xcheck_midpoll_%XCHECK_PROC%=0 >> "%PROBE_LOCAL%" & echo explorer_xcheck_midpoll_%XCHECK_PROC%=0 >> "%PROBE_OUT%") else (echo explorer_xcheck_midpoll_%XCHECK_PROC%=1 >> "%PROBE_LOCAL%" & echo explorer_xcheck_midpoll_%XCHECK_PROC%=1 >> "%PROBE_OUT%")
)
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

:probe_wer_snapshot
rem %1 = suffix: diag, uwp or xcheck. Run 47: the same WER/evtx/dump
rem capture the end snapshot does, but taken mid-run so a wedge in a
rem later section cannot take the breakpoint evidence with it. Every
rem key carries the suffix, so the three snapshots do not collide and
rem the end snapshot keeps its unsuffixed keys (static tests pin the
rem end block's positions and names — do not rename them here).
rem A crash report is only evidence about a death if its queue time is
rem on or after the probe started, so the times are recorded with the
rem names; the host side compares them against the probe markers.
echo mark_wer_%~1=%TIME: =0% >> "%PROBE_LOCAL%" & echo mark_wer_%~1=%TIME: =0% >> "%PROBE_OUT%"
set "WER_SNAP_EXPLORER=0"
set "WER_SNAP_REPORTS=0"
if exist "%ProgramData%\Microsoft\Windows\WER\ReportQueue\*explorer*" (
    set "WER_SNAP_EXPLORER=1"
    for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\*explorer*") do (
        echo wer_%~1_explorer_name=%%~nxD >> "%PROBE_LOCAL%" & echo wer_%~1_explorer_name=%%~nxD >> "%PROBE_OUT%"
        echo wer_%~1_explorer_time=%%~tD >> "%PROBE_LOCAL%" & echo wer_%~1_explorer_time=%%~tD >> "%PROBE_OUT%"
        if defined TASKLIST_OUT (
            echo --- WER %~1 ReportQueue %%~nxD --- >> "%TASKLIST_OUT%"
            type "%%D\Report.wer" >> "%TASKLIST_OUT%" 2>nul
        )
        rem Run 48: the tasklist copy of Report.wer never reached the
        rem host in run 47 — the share view stopped at 12:41, before
        rem the end snapshot typed it. Copy the file itself to the
        rem share: a fresh create+write+close is the channel that
        rem survived run 47 (the local probe copy landed complete at
        rem every section sync), while an append into the live probe
        rem file stalled. The _copy key says whether it landed.
        if defined PROBE_DIR if exist "%%D\Report.wer" (
            copy /y "%%D\Report.wer" "%PROBE_DIR%micpe-wer-explorer-%~1.wer" >nul 2>&1
            if exist "%PROBE_DIR%micpe-wer-explorer-%~1.wer" (echo wer_%~1_wer_copy=1 >> "%PROBE_LOCAL%" & echo wer_%~1_wer_copy=1 >> "%PROBE_OUT%") else (echo wer_%~1_wer_copy=0 >> "%PROBE_LOCAL%" & echo wer_%~1_wer_copy=0 >> "%PROBE_OUT%")
        )
        set /a WER_SNAP_REPORTS+=1
    )
)
if exist "%ProgramData%\Microsoft\Windows\WER\ReportArchive\*explorer*" (
    set "WER_SNAP_EXPLORER=1"
    for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportArchive\*explorer*") do (
        echo wer_%~1_explorer_archive_name=%%~nxD >> "%PROBE_LOCAL%" & echo wer_%~1_explorer_archive_name=%%~nxD >> "%PROBE_OUT%"
        echo wer_%~1_explorer_archive_time=%%~tD >> "%PROBE_LOCAL%" & echo wer_%~1_explorer_archive_time=%%~tD >> "%PROBE_OUT%"
        rem Run 48: same direct copy as the queue loop above — an
        rem archived report is the same breakpoint evidence, and the
        rem tasklist transcription is not a reliable channel.
        if defined PROBE_DIR if exist "%%D\Report.wer" (
            copy /y "%%D\Report.wer" "%PROBE_DIR%micpe-wer-explorer-%~1-archive.wer" >nul 2>&1
            if exist "%PROBE_DIR%micpe-wer-explorer-%~1-archive.wer" (echo wer_%~1_archive_wer_copy=1 >> "%PROBE_LOCAL%" & echo wer_%~1_archive_wer_copy=1 >> "%PROBE_OUT%") else (echo wer_%~1_archive_wer_copy=0 >> "%PROBE_LOCAL%" & echo wer_%~1_archive_wer_copy=0 >> "%PROBE_OUT%")
        )
    )
)
echo wer_%~1_explorer=%WER_SNAP_EXPLORER% >> "%PROBE_LOCAL%" & echo wer_%~1_explorer=%WER_SNAP_EXPLORER% >> "%PROBE_OUT%"
echo wer_%~1_reports=%WER_SNAP_REPORTS% >> "%PROBE_LOCAL%" & echo wer_%~1_reports=%WER_SNAP_REPORTS% >> "%PROBE_OUT%"
if exist "%SystemRoot%\System32\winevt\Logs\System.evtx" (
    echo evtx_%~1_system=1 >> "%PROBE_LOCAL%" & echo evtx_%~1_system=1 >> "%PROBE_OUT%"
    for %%F in ("%SystemRoot%\System32\winevt\Logs\System.evtx") do echo evtx_%~1_system_size=%%~zF >> "%PROBE_LOCAL%" & echo evtx_%~1_system_size=%%~zF >> "%PROBE_OUT%"
    if defined PROBE_DIR copy /y "%SystemRoot%\System32\winevt\Logs\System.evtx" "%PROBE_DIR%micpe-system-%~1.evtx" >nul 2>&1
    if defined PROBE_DIR if exist "%PROBE_DIR%micpe-system-%~1.evtx" (echo evtx_%~1_system_copy=1 >> "%PROBE_LOCAL%" & echo evtx_%~1_system_copy=1 >> "%PROBE_OUT%") else (echo evtx_%~1_system_copy=0 >> "%PROBE_LOCAL%" & echo evtx_%~1_system_copy=0 >> "%PROBE_OUT%")
) else (
    echo evtx_%~1_system=0 >> "%PROBE_LOCAL%" & echo evtx_%~1_system=0 >> "%PROBE_OUT%"
)
if exist "%SystemRoot%\System32\winevt\Logs\Application.evtx" (
    echo evtx_%~1_app=1 >> "%PROBE_LOCAL%" & echo evtx_%~1_app=1 >> "%PROBE_OUT%"
    for %%F in ("%SystemRoot%\System32\winevt\Logs\Application.evtx") do echo evtx_%~1_app_size=%%~zF >> "%PROBE_LOCAL%" & echo evtx_%~1_app_size=%%~zF >> "%PROBE_OUT%"
    if defined PROBE_DIR copy /y "%SystemRoot%\System32\winevt\Logs\Application.evtx" "%PROBE_DIR%micpe-application-%~1.evtx" >nul 2>&1
    if defined PROBE_DIR if exist "%PROBE_DIR%micpe-application-%~1.evtx" (echo evtx_%~1_app_copy=1 >> "%PROBE_LOCAL%" & echo evtx_%~1_app_copy=1 >> "%PROBE_OUT%") else (echo evtx_%~1_app_copy=0 >> "%PROBE_LOCAL%" & echo evtx_%~1_app_copy=0 >> "%PROBE_OUT%")
) else (
    echo evtx_%~1_app=0 >> "%PROBE_LOCAL%" & echo evtx_%~1_app=0 >> "%PROBE_OUT%"
)
if exist "%SystemRoot%\Minidump\*.dmp" (echo dump_%~1_minidump=1 >> "%PROBE_LOCAL%" & echo dump_%~1_minidump=1 >> "%PROBE_OUT%") else (echo dump_%~1_minidump=0 >> "%PROBE_LOCAL%" & echo dump_%~1_minidump=0 >> "%PROBE_OUT%")
if exist "%SystemRoot%\MEMORY.DMP" (echo dump_%~1_memory=1 >> "%PROBE_LOCAL%" & echo dump_%~1_memory=1 >> "%PROBE_OUT%") else (echo dump_%~1_memory=0 >> "%PROBE_LOCAL%" & echo dump_%~1_memory=0 >> "%PROBE_OUT%")
rem Run 49: the same section's dump files, copied to the share now so a
rem wedge in a later section cannot take them with it.
call :probe_dump_copy %~1
exit /b 0

:probe_dump_copy
rem %1 = suffix: diag, uwp, xcheck or end. Run 49: Report.wer alone
rem cannot locate the 0x1181ea call stack — only a minidump can. WER
rem LocalDumps (60-werdumps.reg, CI-time import) writes explorer's dump
rem to X:\CrashDumps when it crashes; the queue entry itself may also
rem hold a .dmp/.hdmp. Copy every dump file to the share (a fresh
rem create+write+close is the channel that survived run 47/48) and
rem record whether one existed and whether a copy landed. Reads and
rem copies only; a missing folder or a locked file leaves 0, never
rem stalls the probe. The per-file loop keeps the original dump name
rem (it carries the crashing PID); the if exist guards skip the
rem no-match case, because an unmatched for pattern runs once literally.
set "DUMP_WER_DMP=0"
set "DUMP_WER_DMP_COPY=0"
set "DUMP_LOCALDUMPS=0"
set "DUMP_LOCALDUMPS_COPY=0"
set "DUMP_PROFILE=0"
set "DUMP_PROFILE_COPY=0"
if defined PROBE_DIR if exist "%ProgramData%\Microsoft\Windows\WER\ReportQueue\*explorer*" (
    for /d %%D in ("%ProgramData%\Microsoft\Windows\WER\ReportQueue\*explorer*") do (
        if exist "%%D\*.dmp" for %%F in ("%%D\*.dmp") do (
            set "DUMP_WER_DMP=1"
            copy /y "%%F" "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" >nul 2>&1
            if exist "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" set "DUMP_WER_DMP_COPY=1"
        )
        if exist "%%D\*.hdmp" for %%F in ("%%D\*.hdmp") do (
            set "DUMP_WER_DMP=1"
            copy /y "%%F" "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" >nul 2>&1
            if exist "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" set "DUMP_WER_DMP_COPY=1"
        )
    )
)
if defined PROBE_DIR if exist "%SystemDrive%\CrashDumps\*.dmp" (
    for %%F in ("%SystemDrive%\CrashDumps\*.dmp") do (
        set "DUMP_LOCALDUMPS=1"
        copy /y "%%F" "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" >nul 2>&1
        if exist "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" set "DUMP_LOCALDUMPS_COPY=1"
    )
)
if defined PROBE_DIR if exist "%SystemRoot%\System32\config\systemprofile\AppData\Local\CrashDumps\*.dmp" (
    for %%F in ("%SystemRoot%\System32\config\systemprofile\AppData\Local\CrashDumps\*.dmp") do (
        set "DUMP_PROFILE=1"
        copy /y "%%F" "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" >nul 2>&1
        if exist "%PROBE_DIR%micpe-minidump-%~1-%%~nxF" set "DUMP_PROFILE_COPY=1"
    )
)
echo dump_%~1_wer_dmp=%DUMP_WER_DMP% >> "%PROBE_LOCAL%" & echo dump_%~1_wer_dmp=%DUMP_WER_DMP% >> "%PROBE_OUT%"
echo dump_%~1_wer_dmp_copy=%DUMP_WER_DMP_COPY% >> "%PROBE_LOCAL%" & echo dump_%~1_wer_dmp_copy=%DUMP_WER_DMP_COPY% >> "%PROBE_OUT%"
echo dump_%~1_localdumps=%DUMP_LOCALDUMPS% >> "%PROBE_LOCAL%" & echo dump_%~1_localdumps=%DUMP_LOCALDUMPS% >> "%PROBE_OUT%"
echo dump_%~1_localdumps_copy=%DUMP_LOCALDUMPS_COPY% >> "%PROBE_LOCAL%" & echo dump_%~1_localdumps_copy=%DUMP_LOCALDUMPS_COPY% >> "%PROBE_OUT%"
echo dump_%~1_profile=%DUMP_PROFILE% >> "%PROBE_LOCAL%" & echo dump_%~1_profile=%DUMP_PROFILE% >> "%PROBE_OUT%"
echo dump_%~1_profile_copy=%DUMP_PROFILE_COPY% >> "%PROBE_LOCAL%" & echo dump_%~1_profile_copy=%DUMP_PROFILE_COPY% >> "%PROBE_OUT%"
exit /b 0

:probe_sc_start
rem %1 = service name, %2 = key prefix. Run 51: start a service
rem detached with a bounded wait (run 39: two start calls stalled
rem probe + watchdog within ~15s, so the parent never blocks on the
rem start command). Writes scstart_<prefix>_done=1 when the child
rem finished in time, scstart_<prefix>_timeout=1 when it did not
rem (the start command is taskkilled). The child writes its output
rem to a temp file on the PE system drive plus a DONE sentinel; the
rem parent waits for DONE, not merely a non-empty file — the start
rem command prints its first line before it finishes, so non-empty
rem alone would read a start still in flight as done. The caller
rem reads the service state afterwards with :probe_svc (the query
rem command is proven safe; only the start call ever wedged).
rem The temp file lives on %SystemDrive% (X: in PE, the RAM disk) so
rem it never touches the share and never waits on the network.
set "SC_TMP=%SystemDrive%\micpe-scstart.tmp"
del "%SC_TMP%" >nul 2>&1
start "" /min cmd /c sc start %~1 ^> "%SC_TMP%" 2^>nul ^& echo DONE ^>^> "%SC_TMP%"
set /a SC_SPIN=0
set /a SC_WAIT=0
:sc_start_spin
if exist "%SC_TMP%" for %%F in ("%SC_TMP%") do if %%~zF gtr 0 goto sc_start_check_done
set /a SC_SPIN+=1
if %SC_SPIN% lss 20000 goto sc_start_spin
:sc_start_wait
if exist "%SC_TMP%" for %%F in ("%SC_TMP%") do if %%~zF gtr 0 goto sc_start_check_done
if %SC_WAIT% geq 15 goto sc_start_timeout
choice /c Y /d Y /t 1 >nul
set /a SC_WAIT+=1
goto sc_start_wait
:sc_start_check_done
find /i "DONE" "%SC_TMP%" >nul 2>&1
if not errorlevel 1 goto sc_start_found
if %SC_WAIT% geq 15 goto sc_start_timeout
choice /c Y /d Y /t 1 >nul
set /a SC_WAIT+=1
goto sc_start_check_done
:sc_start_found
echo scstart_%~2_done=1 >> "%PROBE_LOCAL%" & echo scstart_%~2_done=1 >> "%PROBE_OUT%"
del "%SC_TMP%" >nul 2>&1
exit /b 0
:sc_start_timeout
echo scstart_%~2_timeout=1 >> "%PROBE_LOCAL%" & echo scstart_%~2_timeout=1 >> "%PROBE_OUT%"
taskkill /f /im sc.exe >nul 2>&1
del "%SC_TMP%" >nul 2>&1
exit /b 1

:probe_poll_check
rem %1 = process image name (no .exe). Run 47: run 46 died between a
rem poll round's wait_after and check_after — the only step in between
rem is the tasklist|find pipeline, so a hung tasklist enumeration
rem kills the probe outright. Run tasklist detached in a child cmd
rem writing to a temp file on the PE system drive, then wait for the
rem child to finish with a bounded spin plus two one-second choice
rem ticks; on timeout record tasklist_timeout_<proc>=1 (dual-written),
rem try to kill the hung tasklist, and return 1 (not found) so the
rem poll loop continues instead of dying with the probe. The parent
rem never pipes from tasklist directly, so a wedged enumeration cannot
rem hang the probe. Returns errorlevel 0 when the process is listed.
rem The temp file lives on %SystemDrive% (X: in PE, the RAM disk) so
rem it never touches the share and never waits on the network.
rem The child appends a DONE sentinel after tasklist exits, and the
rem parent waits for the file to be NON-EMPTY, not merely to exist:
rem the redirection creates the file the moment the child starts, so
rem existence alone proves nothing — a blocked child leaves an empty
rem file behind, and an existence check would read it as "answered"
rem at once (CI run 44517188618 P3: the timeout key never got
rem written because the empty file short-circuited the wait).
set "POLL_TMP=%SystemDrive%\micpe-poll.tmp"
del "%POLL_TMP%" >nul 2>&1
start "" /min cmd /c tasklist /fi "imagename eq %~1.exe" /nh ^> "%POLL_TMP%" 2^>nul ^& echo DONE ^>^> "%POLL_TMP%"
set /a POLL_SPIN=0
:poll_check_spin
if exist "%POLL_TMP%" for %%F in ("%POLL_TMP%") do if %%~zF gtr 0 goto poll_check_found
set /a POLL_SPIN+=1
if %POLL_SPIN% lss 20000 goto poll_check_spin
set /a POLL_WAIT=0
:poll_check_wait
if exist "%POLL_TMP%" for %%F in ("%POLL_TMP%") do if %%~zF gtr 0 goto poll_check_found
if %POLL_WAIT% geq 2 goto poll_check_timeout
choice /c Y /d Y /t 1 >nul
set /a POLL_WAIT+=1
goto poll_check_wait
:poll_check_found
find /i "%~1.exe" "%POLL_TMP%" >nul
if not errorlevel 1 (
    del "%POLL_TMP%" >nul 2>&1
    exit /b 0
)
del "%POLL_TMP%" >nul 2>&1
exit /b 1
:poll_check_timeout
echo tasklist_timeout_%~1=1 >> "%PROBE_LOCAL%" & echo tasklist_timeout_%~1=1 >> "%PROBE_OUT%"
taskkill /f /im tasklist.exe >nul 2>&1
del "%POLL_TMP%" >nul 2>&1
exit /b 1

:probe_sync_local
rem Run 47: the share probe file is written through the vvfat share,
rem which run 46 proved can silently zero-fill a whole stretch (724
rem NUL bytes, 14 lines lost, uwp_launch_calculator among them). The
rem local file on the PE system drive (X:, RAM disk) never goes
rem through the share, so copy it to the share at the end of every
rem section — the harness uploads that copy, and a NUL hole in the
rem live probe file no longer eats a conclusion. A no-op when
rem PROBE_DIR is unset (local test runs).
if defined PROBE_DIR copy /y "%PROBE_LOCAL%" "%PROBE_DIR%micpe-probe-local.txt" >nul 2>&1
exit /b 0

:probe_svc_reg
rem %1 = service name, %2 = key prefix. Run 48: read the service's
rem start config straight from the SCM and the registry so the stage
rem can say WHY a deployment service never runs — the Start type
rem (3 = manual: nothing ever starts it unless asked), the ServiceDll
rem the SCM would load, whether that file exists, and the account it
rem would run as. Together with the queryex exit codes, these keys
rem separate "never asked to start" from "asked and failed".
rem Reads only; never starts anything — the run 39 control (no
rem sc start in this probe) stays in force. The goto avoids a
rem parenthesised block: %SVC_REG_DLL_X% would expand at block-parse
rem time, before the call set line runs.
rem Run 49: sc qc prints NOTHING in this PE (run 48 proved it — the two
rem queryex title lines sit adjacent in the tasklist file with no output
rem between), so svc_*_start stayed missing. Read the Start value
rem straight from the service key instead — the same for /f tokens=3
rem shape run 42/43 already proved for Serial/Serenum. A missing key
rem leaves missing; a present value is the hex DWORD (0x2 auto, 0x3
rem manual, 0x4 disabled). The sc qc reads stay: on a fuller image
rem they may print again, and the two sources cross-check each other.
set "SVC_REG_START=missing"
set "SVC_REG_START_REG=missing"
set "SVC_REG_DLL=missing"
set "SVC_REG_DLL_EXISTS=0"
set "SVC_REG_OBJ=missing"
set "SVC_REG_DLL_X="
for /f "tokens=3" %%A in ('sc qc %1 2^>nul ^| find /i "START_TYPE"') do set "SVC_REG_START=%%A"
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\%1" /v Start 2^>nul ^| find /i "Start"') do set "SVC_REG_START_REG=%%A"
for /f "tokens=2,*" %%A in ('sc qc %1 2^>nul ^| find /i "SERVICE_START_NAME"') do set "SVC_REG_OBJ=%%B"
for /f "tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\%1\Parameters" /v ServiceDll 2^>nul ^| find /i "ServiceDll"') do set "SVC_REG_DLL=%%B"
if "%SVC_REG_DLL%"=="missing" goto :svc_reg_write
call set "SVC_REG_DLL_X=%SVC_REG_DLL%"
if exist "%SVC_REG_DLL_X%" set "SVC_REG_DLL_EXISTS=1"
:svc_reg_write
echo svc_%2_start=%SVC_REG_START% >> "%PROBE_LOCAL%" & echo svc_%2_start=%SVC_REG_START% >> "%PROBE_OUT%"
echo svc_%2_regstart=%SVC_REG_START_REG% >> "%PROBE_LOCAL%" & echo svc_%2_regstart=%SVC_REG_START_REG% >> "%PROBE_OUT%"
echo svc_%2_dll=%SVC_REG_DLL% >> "%PROBE_LOCAL%" & echo svc_%2_dll=%SVC_REG_DLL% >> "%PROBE_OUT%"
echo svc_%2_dll_exists=%SVC_REG_DLL_EXISTS% >> "%PROBE_LOCAL%" & echo svc_%2_dll_exists=%SVC_REG_DLL_EXISTS% >> "%PROBE_OUT%"
echo svc_%2_obj=%SVC_REG_OBJ% >> "%PROBE_LOCAL%" & echo svc_%2_obj=%SVC_REG_OBJ% >> "%PROBE_OUT%"
exit /b 0
