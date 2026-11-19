@echo off
rem probe-mirror.cmd — detached companion to probe.cmd (run 44428428849).
rem
rem The serial channel is dead (run 42: COM1 cannot be opened in PE,
rem no \Device\Serial0 enumerated, zero sync lines in the serial log),
rem so the local mirror file on %SystemDrive% has no retrieval path:
rem the share is the suspect in the freeze, and X: is a RAM disk that
rem vanishes when QEMU exits. The harness attaches a second vvfat
rem volume (the mirror drive, carrying a micpe-mirror.txt sentinel)
and this companion copies the local mirror file there every few
rem seconds. The host reads it straight from the mirror directory
rem after QEMU exits, without the share: if the share probe stops
rem growing while the mirror copy keeps growing, the guest is alive
rem and the share is wedged; if both stop, the guest itself froze
rem (or both volumes wedged at once — two independent vvfat instances
rem wedging together is the residual ambiguity, see eval card §29).
rem It never writes to the share: a share write is exactly the
rem operation under suspicion. It stops when it sees probe_done=1 in
rem the local file, or when probe.cmd writes the stop flag before the
rem long installer deploy. A final copy runs on either stop so the
rem mirror holds the last line the probe wrote.
rem
rem Usage: probe-mirror.cmd <local-probe-file> <mirror-dir>
rem   The mirror dir is the drive the probe found the sentinel on
rem   (e.g. D:\, trailing backslash included). In mechanism tests it
rem   is a plain directory, also with a trailing backslash.
rem
rem Like probe-sync.cmd, this script never returns a failure exit code
rem for a dead probe: it only reports. A probe that stalls is the
rem watchdog's verdict; a probe that finishes is this script's stop
rem condition. exit /b 0 on every path.
rem
rem Tick shape mirrors the sync: one copy every 5 seconds in
rem 5-second choice ticks. A 60-second choice hung in run 38; the
rem 5-second ticks ran clean through runs 38-42.

setlocal EnableExtensions DisableDelayedExpansion
set "MIRROR_LOCAL=%~1"
set "MIRROR_DIR=%~2"
if not defined MIRROR_LOCAL exit /b 0
if not defined MIRROR_DIR exit /b 0
set "MIRROR_DEST=%MIRROR_DIR%micpe-probe-local.txt"

:mirror_loop
rem Stop when the probe finished (probe_done in the local file) or
rem when probe.cmd wrote the stop flag before the long installer
rem deploy; either way copy once more, then leave. The findstr
rem check sits inside the if-exist block so a missing local file
rem cannot inherit a stale errorlevel and stop the watcher early.
if exist "%SystemDrive%\micpe-watchdog-stop.txt" goto :mirror_final
if exist "%MIRROR_LOCAL%" (
    findstr /b /c:"probe_done=1" "%MIRROR_LOCAL%" >nul 2>&1
    if not errorlevel 1 goto :mirror_final
)
rem Copy the whole local file; it is small (a few KB) and the copy is
rem the only write this script ever makes. A wedged mirror drive
rem fails the copy silently and the next tick retries; the probe
rem itself never touches the mirror drive, so a stuck copy cannot
rem stall the probe.
if exist "%MIRROR_LOCAL%" copy /y "%MIRROR_LOCAL%" "%MIRROR_DEST%" >nul 2>&1
rem Wait one interval, then copy again.
choice /c Y /d Y /t 5 >nul
goto :mirror_loop

:mirror_final
if exist "%MIRROR_LOCAL%" copy /y "%MIRROR_LOCAL%" "%MIRROR_DEST%" >nul 2>&1
exit /b 0
