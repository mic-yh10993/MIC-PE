@echo off
rem ==========================================================================
rem  MICPE boot entry
rem
rem  Installed by the build as %SystemRoot%\System32\startnet.cmd, which is the
rem  file winpeshl.exe runs. It only sequences the phases and never touches the
rem  desktop itself, so the boot order can be read top to bottom in one screen.
rem
rem      phases\10-osinit.cmd     wpeinit, hide the Startup folder, WinXShell init
rem      phases\20-preshell.cmd   USERPROFILE / Desktop / Programs
rem      phases\25-logon.cmd      Administrator logon token for the shell
rem      phases\30-runshell.cmd   explorer.exe, or WinXShell as the fallback
rem      phases\40-postshell.cmd  taskbar ready, hide this console, diagnostics
rem
rem  To add your own startup work, drop a .cmd into hooks\<phase>\ instead of
rem  editing these files: every hook is called in name order at the end of its
rem  phase. See ..\README.md.
rem
rem  No PECMD and no WimBuilder2 runner in this chain: the phases below are this
rem  project's own code, so every step is readable and editable here.
rem ==========================================================================

setlocal EnableExtensions
set "MICPE=%SystemRoot%\System32\MICPE"

if not exist "%MICPE%\phases\10-osinit.cmd" (
    echo MICPE: %MICPE%\phases is missing - cannot continue.
    goto :END
)

call "%MICPE%\phases\10-osinit.cmd"
call "%MICPE%\phases\20-preshell.cmd"
call "%MICPE%\phases\25-logon.cmd"
call "%MICPE%\phases\30-runshell.cmd"
call "%MICPE%\phases\40-postshell.cmd"

:END
rem Do not use exit /b here: winpeshl owns this console and must get control
rem back. 40-postshell.cmd is what hides the window on a healthy boot.
endlocal
