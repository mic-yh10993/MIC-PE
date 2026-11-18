@echo off
rem probe-sync.cmd — detached companion to probe.cmd (run 44386689307).
rem
rem The probe writes every section marker to the local mirror file on
rem %SystemDrive% FIRST and to the share second. This watcher echoes the
rem local file's last line to the serial log every few seconds, so the
rem host can tell a wedged share from a frozen guest without the share:
rem   serial markers keep coming, same last line repeating -> the guest
rem   is alive and the probe is stuck on a share write (vvfat)
rem   serial markers stop entirely -> the guest itself froze
rem It never writes to the share: a share write is exactly the operation
rem under suspicion. It stops when it sees probe_done=1 in the local
rem file, or when probe.cmd writes the stop flag before the long
rem installer deploy.
rem
rem Usage: probe-sync.cmd <local-probe-file> [interval-seconds] [serial-device]
rem   interval defaults to 5; serial device defaults to COM1 (the QEMU
rem   serial log, collected into the verify artifact by build.yml).
rem   In mechanism tests the serial device is a plain file.
rem
rem Like the watchdog, this script never returns a failure exit code
rem for a dead probe: it only reports. A probe that stalls is the
rem watchdog's verdict; a probe that finishes is this script's stop
rem condition. exit /b 0 on every path.
rem
rem Tick shape mirrors the watchdog: one report every SYNC_INTERVAL
rem seconds, in 5-second choice ticks. A 60-second choice hung in
rem run 38; the 5-second ticks ran clean through runs 38-40.

setlocal EnableExtensions DisableDelayedExpansion
set "SYNC_LOCAL=%~1"
set "SYNC_INTERVAL=%~2"
set "SYNC_SERIAL=%~3"
if not defined SYNC_INTERVAL set "SYNC_INTERVAL=5"
if not defined SYNC_SERIAL set "SYNC_SERIAL=COM1"
if not defined SYNC_LOCAL exit /b 0
set /a SYNC_TICKS=%SYNC_INTERVAL% / 5
if %SYNC_TICKS% lss 1 set "SYNC_TICKS=1"
set /a SYNC_TICKLEN=%SYNC_INTERVAL% / %SYNC_TICKS%

echo sync_start=%TIME: =0% >> "%SYNC_SERIAL%" 2>nul

:sync_loop
rem Stop when the probe finished (probe_done in the local file) or
rem when probe.cmd wrote the stop flag before the long installer
rem deploy; either way there is nothing left to report. The findstr
rem check sits inside the if-exist block so a missing local file
rem cannot inherit a stale errorlevel and stop the watcher early.
if exist "%SystemDrive%\micpe-watchdog-stop.txt" exit /b 0
if exist "%SYNC_LOCAL%" (
    findstr /b /c:"probe_done=1" "%SYNC_LOCAL%" >nul 2>&1
    if not errorlevel 1 exit /b 0
)
rem Report the local file's last line; when the file is missing or
rem empty, report that instead of guessing.
set "SYNC_LAST="
if exist "%SYNC_LOCAL%" for /f "usebackq delims= eol=" %%L in (`type "%SYNC_LOCAL%"`) do set "SYNC_LAST=%%L"
if defined SYNC_LAST (
    echo sync %TIME: =0% last=%SYNC_LAST% >> "%SYNC_SERIAL%" 2>nul
) else (
    echo sync %TIME: =0% last=^<no local probe^> >> "%SYNC_SERIAL%" 2>nul
)
rem Wait one interval, then report again.
set "SYNC_TICK=0"
:sync_wait
if exist "%SystemDrive%\micpe-watchdog-stop.txt" exit /b 0
if exist "%SYNC_LOCAL%" (
    findstr /b /c:"probe_done=1" "%SYNC_LOCAL%" >nul 2>&1
    if not errorlevel 1 exit /b 0
)
choice /c Y /d Y /t %SYNC_TICKLEN% >nul
set /a SYNC_TICK+=1
if %SYNC_TICK% lss %SYNC_TICKS% goto :sync_wait
goto :sync_loop
