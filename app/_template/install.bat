@echo off
rem Template for app/<component>/install.bat
rem
rem Called by the M5 payload step as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem %1 = mounted image root (e.g. D:\micpe\mount)
rem %2 = repo root
rem Must be idempotent and exit 0 on success, non-zero on failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2

rem --- fill in below: copy this component's files into the image ---
rem Two fixed destinations (see app/README.md): program files go to
rem "%MOUNT%\Program Files\MICPE\<component>", config files and
rem self-implemented tools go to "%MOUNT%\Windows\System32\MICPE".
rem set "DEST=%MOUNT%\Program Files\MICPE\<component>"
rem if exist "%DEST%" rmdir /s /q "%DEST%"
rem mkdir "%DEST%"
rem xcopy /e /i /y "%~dp0files" "%DEST%"

echo <component> installed.
exit /b 0
