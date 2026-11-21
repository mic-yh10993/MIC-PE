@echo off
setlocal EnableExtensions
rem MICPE experimental native-logon bootstrap.
rem SYSTEM is used only for PE initialization and account preparation.
rem The intended desktop must be created by a real Winlogon logon.

set "LOG=%SystemRoot%\System32\MICPE\native-logon-bootstrap.log"
set "DONE=%SystemRoot%\System32\MICPE\native-logon-bootstrap.done"

if exist "%DONE%" exit /b 0

if not exist "%SystemRoot%\System32\MICPE" md "%SystemRoot%\System32\MICPE"
echo [%date% %time%] native-logon bootstrap started > "%LOG%"

wpeinit
if errorlevel 1 echo [%date% %time%] WARNING: wpeinit returned %errorlevel%>>"%LOG%"

if exist "%SystemRoot%\System32\MICPE\Fix-DriveLetters.cmd" (
    call "%SystemRoot%\System32\MICPE\Fix-DriveLetters.cmd" >>"%LOG%" 2>&1
)

rem This is intentionally an experiment against the built-in account.
rem Do not create a new account: it would not have the machine RID-500 SID.
rem On some localized images the built-in account name is localized;
rem if "Administrator" is not found, stop here rather than creating one.
net user Administrator >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] ERROR: built-in account name Administrator not found.>>"%LOG%"
    echo Native logon bootstrap stopped. See %LOG%
    cmd.exe
    exit /b 1
)

rem Enable the existing built-in account and set its password to empty.
net user Administrator "" /active:yes >>"%LOG%" 2>&1
if errorlevel 1 (
    echo [%date% %time%] ERROR: net user could not enable/set the account.>>"%LOG%"
    cmd.exe
    exit /b 1
)

rem Disable automatic logon for the next Winlogon transition.
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" ^
    /v AutoAdminLogon /t REG_SZ /d 0 /f >>"%LOG%" 2>&1
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" ^
    /v DefaultUserName /t REG_SZ /d Administrator /f >>"%LOG%" 2>&1
reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" ^
    /v DefaultPassword /f >>"%LOG%" 2>&1

echo [%date% %time%] account prepared; requesting logoff.>>"%LOG%"
echo 1>"%DONE%"

rem Do not start LogonUI.exe directly. Let Winlogon own the logon UI.
shutdown.exe /l
if errorlevel 1 (
    echo [%date% %time%] shutdown /l failed; trying logoff.exe.>>"%LOG%"
    logoff.exe
)

echo [%date% %time%] ERROR: logoff returned to startnet.>>"%LOG%"
del "%DONE%" >nul 2>&1
cmd.exe
exit /b 1
