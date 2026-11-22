@echo off
rem ==========================================================================
rem  MICPE UWP runtime - state dump
rem
rem  Installed to %SystemRoot%\System32\MICPE\uwp-diag.cmd by the build.
rem
rem  Pure cmd.exe on purpose: this image has no powershell.exe and no
rem  whoami.exe, so anything calling them prints "not recognized" instead of
rem  the answer (an earlier image's whole dump was three such lines). Only tools
rem  the image is known to carry are used - reg, sc, tasklist, find, dir, type.
rem
rem  Everything goes to the console and to logs\uwp-diag.log, and the log is
rem  copied to the first writable volume so it survives the RAM disk.
rem ==========================================================================

setlocal EnableExtensions
set "MICPE=%~dp0"
set "LOG=%MICPE%logs\uwp-diag.log"
if not exist "%MICPE%logs" md "%MICPE%logs%" >nul 2>&1

call :OUT "=== MICPE UWP diagnostic ==="
call :OUT "date: %DATE% %TIME%"
call :OUT "user: %USERNAME%  session: %SESSIONNAME%  computer: %COMPUTERNAME%"
call :OUT "root: %SystemRoot%  drive: %SystemDrive%"

call :OUT ""
call :OUT "--- shell configuration ---"
call :RUN reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell
call :RUN reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Userinit
call :RUN reg query "HKLM\SYSTEM\Setup" /v SystemSetupInProgress
call :RUN reg query "HKLM\SYSTEM\Setup" /v SetupType
call :RUN reg query "HKLM\SOFTWARE\Microsoft\Windows\DWM" /v OneCoreNoBootDWM
call :RUN dir "%SystemRoot%\explorer.exe"

call :OUT ""
call :OUT "--- processes ---"
for %%P in (explorer.exe dwm.exe winlogon.exe csrss.exe sihost.exe ShellExperienceHost.exe StartMenuExperienceHost.exe RuntimeBroker.exe) do call :PROC %%P

call :OUT ""
call :OUT "--- services ---"
for %%S in (AppXSvc AppReadiness ClipSVC Themes CoreMessagingRegistrar StateRepository ProfSvc Appinfo ShellHWDetection) do call :SVC %%S

call :OUT ""
call :OUT "--- payload ---"
call :RUN dir "X:\ProgramData\Microsoft\Windows\AppRepository"
call :RUN dir "X:\Program Files\WinXShell"

call :OUT ""
call :OUT "--- shell integration ---"
rem Recycle Bin: the shell folder enumerates the per-volume store. An absent
rem X:\$Recycle.Bin is the first thing to rule out when the icon does nothing.
call :RUN dir "X:\$Recycle.Bin"
rem Ctrl+Alt+Del: winlogon forwards the SAS to LogonUI. No LogonUI in the
rem image means no security screen, whatever the registry says.
call :RUN dir "%SystemRoot%\System32\LogonUI.exe"
call :RUN reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DisableCAD
rem The logon token decides whether the shell is a real shell: with a logon
rem token Explorer owns a session, without one it only draws the desktop.
call :RUN dir "%MICPE%\logs\logon-token.flag"
call :OUT "  explorer processes:"
tasklist /fi "imagename eq explorer.exe" 2>nul | find /i "explorer.exe" >nul 2>&1
call :OUT "  (count above; two Explorer processes mean two shells fight)"
rem StartAllBack: files in place, settings landed, and - the only proof that
rem matters - whether explorer actually mapped its hook DLL into the process.
call :RUN dir "X:\Program Files\StartAllBack\StartAllBackX64.dll"
call :RUN reg query "HKCU\Software\StartIsBack"
call :RUN dir "X:\Program Files\Start11\Start11_64.exe"
>>"%LOG%" echo [%DATE% %TIME%] ^> tasklist /m /fi "imagename eq explorer.exe"
tasklist /m /fi "imagename eq explorer.exe" >>"%LOG%" 2>&1

call :OUT ""
call :OUT "--- boot phases ---"
if exist "%MICPE%\logs\boot.log" (
    type "%MICPE%\logs\boot.log"
) else (
    call :OUT "(no boot.log - startnet.cmd never reached phase 10)"
)
call :OUT ""
call :OUT "--- shell attempt ---"
if exist "%MICPE%\logs\uwp-shell.log" (
    type "%MICPE%\logs\uwp-shell.log"
) else (
    call :OUT "(no uwp-shell.log - uwp-start-shell.cmd was not run)"
)

call :OUT ""
call :OUT "done. log: %LOG%"

rem -- leave a copy where the host can read it (X: is a RAM disk)
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\" (
        >>"%%D:\micpe-uwp-diag.tmp" echo probe
        if exist "%%D:\micpe-uwp-diag.tmp" (
            copy /y "%LOG%" "%%D:\micpe-uwp-diag.log" >nul 2>&1
            del /q "%%D:\micpe-uwp-diag.tmp" >nul 2>&1
        )
    )
)

endlocal
exit /b 0

:PROC
tasklist /fi "imagename eq %1" 2>nul | find /i "%1" >nul 2>&1
if errorlevel 1 (call :OUT "  %1 : not running") else (call :OUT "  %1 : running")
exit /b 0

:SVC
sc query %1 2>nul | find /i "STATE" >nul 2>&1
if errorlevel 1 (
    call :OUT "  %1 : not installed"
    exit /b 0
)
sc query %1 2>nul | find /i "RUNNING" >nul 2>&1
if errorlevel 1 (call :OUT "  %1 : not running") else (call :OUT "  %1 : RUNNING")
exit /b 0

:RUN
>>"%LOG%" echo [%DATE% %TIME%] ^> %*
%* >>"%LOG%" 2>&1
exit /b 0

:OUT
>>"%LOG%" echo [%DATE% %TIME%] %*
echo %*
exit /b 0
