@echo off
rem ==========================================================================
rem  MICPE UWP runtime - start the shell by hand
rem
rem  The boot chain (startnet.cmd -> phases\30-runshell.cmd) starts the shell
rem  detached and does not retry it, so a failure leaves this console open and
rem  quiet. This script is for that console: it starts explorer once, waits for
rem  it and prints the exit code, which is the only trace a shell that dies on
rem  load ever leaves behind.
rem
rem      0xC0000135 / -1073741515  STATUS_DLL_NOT_FOUND     import missing
rem      0xC0000142 / -1073741502  STATUS_DLL_INIT_FAILED   DllMain failed
rem      0xC0000005 / -1073741819  STATUS_ACCESS_VIOLATION
rem
rem  If explorer stays up, "start /wait" simply never returns and the desktop is
rem  there - close the console window yourself in that case.
rem ==========================================================================

setlocal EnableExtensions
set "MICPE=%~dp0"
set "LOG=%MICPE%logs\uwp-shell.log"
if not exist "%MICPE%\logs" md "%MICPE%\logs%" >nul 2>&1

call :SAY "manual shell start"
if not exist "%SystemRoot%\explorer.exe" (
    call :SAY "explorer.exe missing under %SystemRoot%"
    endlocal
    exit /b 1
)

start "" /wait "%SystemRoot%\explorer.exe"
call :SAY "explorer_exit=%errorlevel%"
endlocal
exit /b 0

:SAY
>>"%LOG%" echo [%DATE% %TIME%] %*
echo %*
exit /b 0
