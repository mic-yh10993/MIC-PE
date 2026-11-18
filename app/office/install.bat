@echo off
rem Office 2016 integration (packaging round): runs in CI against a mounted boot.wim.
rem It NEVER runs inside the PE: do not install software from inside PE,
rem that wastes performance. The PE only contains the files this script
rem already integrated: copy files, write registry, done.
rem
rem Called by the M5 payload step as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem %1 = mounted image root (e.g. D:\micpe\mount)
rem %2 = repo root
rem The slimmed archive (office2016-slim.7z) is staged next to this script
rem by the payload step. It was built from the Office 2016 green archive
rem (see app/office/README.md): Access removed, the vendor's install /
rem uninstall scripts removed, Office self-activation kept.
rem Must be idempotent and exit 0 on success, non-zero on failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2
set "ARCHIVE=%~dp0office2016-slim.7z"
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
