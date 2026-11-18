@echo off
rem MICPE probe watchdog (run 44285721257).
rem
rem Watches the probe file probe.cmd writes. The probe records its own
rem probe_done=1 at the end, but a stall or crash mid-run (Photos hung
rem the UWP launch in run 44285721257) writes nothing, and the CI host
rem then waits out the full 45 minutes for a line that will never come.
rem This watcher runs detached alongside the probe: when the probe file
rem stops growing for 5 minutes, it records probe_failed=1 itself, so
rem the host stops waiting early. probe_failed still fails the run,
rem see Assert-Probe; it only shortens the wait, it never passes one.
rem The watcher stops on its own when it sees probe_done=1, or when
rem probe.cmd writes the stop flag before the long installer deploy.
rem
rem Heartbeat (run 44303866765): the run 35 watchdog process was alive
rem (its empty-title minimized window was on the screenshot) yet never
rem wrote probe_failed=1 in 34 quiet minutes, and there was no evidence
rem of which loop step it was stuck on. Every loop iteration now appends
rem lines to micpe-watchdog-heartbeat.txt next to the probe file on
rem the share, so the CI host can see the loop run: time, quiet count
rem and the file size it observed. The heartbeat is a separate file on
rem purpose: writing it into the probe file would grow the probe file
rem and reset this watcher's own quiet count. The heartbeat file is
rem collected into the verify artifact by build.yml; a heartbeat on X:
rem would be invisible to the host after shutdown.
rem Run 44319967017: the heartbeat proved the loop died in round 2 but
rem could not say whether it died in the wait or in the next round's
rem file work, so each round now writes two lines (phase=before_wait
rem before the wait, phase=after_wait after it). The wait itself is
rem choice, not ping: ping is the prime suspect for the round-2 stall,
rem and choice.exe is in the image (20-explorer.txt:126, verified
rem present in the run 27 boot.wim). choice /c Y /d Y /t N waits N
rem seconds then takes the default; its errorlevel is ignored.
rem Run 44349189039: the single 60-second choice wait never returned in
rem run 38 (before_wait written 17:02:42.67, after_wait never appeared),
rem while the probe's 1-second choice waits returned 30 times in the
rem same run. A long single wait can swallow a whole round without a
rem trace, so the wait is split into short ticks of at most 5 seconds
rem with a heartbeat line after each tick (phase=wait_tick): a partial
rem heartbeat says which tick it died in, and the tick loop is the
rem same total wait (60 seconds by default). Small values used by the
rem mechanism tests (WD_WAIT=2) stay a single tick of the same length,
rem so the total wait is unchanged there.
rem
rem Usage: probe-watchdog.cmd <probe-file> [stall-limit] [wait-seconds]
rem Defaults: 5 quiet checks of 60 seconds each. The two optional
rem arguments exist only so the Pester mechanism tests can run the
rem same script with small numbers; the PE call passes just the file.
setlocal
set "WD_FILE=%~1"
if not defined WD_FILE exit /b 2
set "WD_LIMIT=%~2"
if not defined WD_LIMIT set "WD_LIMIT=5"
set "WD_WAIT=%~3"
if not defined WD_WAIT set "WD_WAIT=60"
set "WD_STOP=%SystemDrive%\micpe-watchdog-stop.txt"
set "WD_HEARTBEAT=%~dp1micpe-watchdog-heartbeat.txt"
set "WD_SIZE="
set "WD_QUIET=0"
echo watchdog_start=%TIME: =0% >> "%WD_HEARTBEAT%"
:watchdog_loop
findstr /b /c:"probe_done=1" "%WD_FILE%" >nul 2>&1
if not errorlevel 1 exit /b 0
if exist "%WD_STOP%" exit /b 0
for %%F in ("%WD_FILE%") do set "WD_NOW=%%~zF"
if "%WD_NOW%"=="%WD_SIZE%" (
    set /a WD_QUIET+=1
) else (
    set "WD_SIZE=%WD_NOW%"
    set "WD_QUIET=0"
)
echo %TIME: =0% quiet=%WD_QUIET% size=%WD_NOW% phase=before_wait >> "%WD_HEARTBEAT%"
if %WD_QUIET% geq %WD_LIMIT% goto :watchdog_fail
rem Split the wait into short choice ticks (run 44349189039): a single
rem 60-second choice wait never returned in run 38, while 1-second
rem waits returned every time. WD_WAIT=60 becomes 12 ticks of 5 seconds;
rem WD_WAIT below 5 stays one tick of the same length.
set /a WD_TICKS=%WD_WAIT% / 5
if %WD_TICKS% lss 1 set "WD_TICKS=1"
set /a WD_TICKLEN=%WD_WAIT% / %WD_TICKS%
set "WD_TICK=0"
:watchdog_wait_tick
choice /c Y /d Y /t %WD_TICKLEN% >nul
set /a WD_TICK+=1
echo %TIME: =0% phase=wait_tick tick=%WD_TICK%/%WD_TICKS% >> "%WD_HEARTBEAT%"
if %WD_TICK% lss %WD_TICKS% goto :watchdog_wait_tick
echo %TIME: =0% quiet=%WD_QUIET% size=%WD_NOW% phase=after_wait >> "%WD_HEARTBEAT%"
goto :watchdog_loop
:watchdog_fail
if not exist "%WD_FILE%" exit /b 1
findstr /b /c:"probe_done=1" "%WD_FILE%" >nul 2>&1
if not errorlevel 1 exit /b 0
echo probe_failed=1 >> "%WD_FILE%"
echo %TIME: =0% probe_failed_written=1 >> "%WD_HEARTBEAT%"
exit /b 1
