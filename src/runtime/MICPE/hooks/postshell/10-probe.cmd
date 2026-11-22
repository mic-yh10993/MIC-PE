@echo off
rem ==========================================================================
rem  wb2 probe launcher - runs the wb2 self check detached
rem
rem  Starts probe-wb2.cmd in a separate window so the 15-second settle wait
rem  inside it never blocks the postshell phase. The probe writes
rem  micpe-probe.txt to the vvfat share (or X: when no share exists) and
rem  ends with probe_done=1; it does NOT shut the guest down - the QEMU
rem  harness takes the final screenshot first, then quits QEMU itself.
rem
rem  On real hardware (no vvfat share) the probe still runs and writes to
rem  X:\micpe-probe.txt; it is harmless there, and the file is useful
rem  diagnostics for a manual boot.
rem ==========================================================================

start "" /min cmd /c "%SystemRoot%\System32\MICPE\probe-wb2.cmd"
goto :EOF
