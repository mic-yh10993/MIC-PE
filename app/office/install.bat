@echo off
rem Office 2016 green integration (M5): runs in CI against a mounted boot.wim.
rem It NEVER runs inside the PE: do not install software from inside PE,
rem that wastes performance. The PE only contains the files this script
rem already integrated: copy files, write registry, done.
rem
rem Called by the M5 payload step as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem %1 = mounted image root (e.g. D:\micpe\mount)
rem %2 = repo root
rem The 7z is staged next to this script by the payload step.
rem Must be idempotent and exit 0 on success, non-zero on failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2
set "ARCHIVE=%~dp0office2016-green.7z"
if not exist "%ARCHIVE%" echo office archive not staged next to install.bat: %ARCHIVE%& exit /b 2

rem The archive's top level is Office2016\, so extracting into
rem "Program Files" lands it as Program Files\Office2016\...
set "DEST=%MOUNT%\Program Files\Office2016"
if exist "%DEST%" rmdir /s /q "%DEST%"
7z x "%ARCHIVE%" "-o%MOUNT%\Program Files" -y
if errorlevel 1 echo 7z extract failed& exit /b 1
if not exist "%DEST%\Office16\WINWORD.EXE" echo office extract incomplete: WINWORD.EXE missing& exit /b 1

echo office installed.
exit /b 0
