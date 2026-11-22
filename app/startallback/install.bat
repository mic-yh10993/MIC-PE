@echo off
rem StartAllBack 3.6 integration - runs in CI against a mounted boot.wim.
rem It never runs inside the PE: the image only carries the files this script
rem copied, plus the registrations in reg\ (imported by the build step).
rem
rem Called by the UWP chain as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem %1 = mounted image root (e.g. E:\micpe\mount)
rem %2 = repo root (unused here: the payload sits next to this script)
rem
rem Target layout is StartAllBack's own: X:\Program Files\StartAllBack, because
rem the registrations hardcode that path and the binary looks for its Styles\
rem and Orbs\ next to itself. Do not move it into Program Files\MICPE.
rem
rem Idempotent: the destination is wiped first, so a rebuild never merges two
rem versions. Exit 0 on success, non-zero on the first failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2

set "SRC=%~dp0files"
set "DEST=%MOUNT%\Program Files\StartAllBack"
if not exist "%SRC%\StartAllBackX64.dll" echo StartAllBack payload missing: %SRC%\StartAllBackX64.dll& exit /b 2

if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"
xcopy "%SRC%\*" "%DEST%\" /e /h /i /q /y >nul
if errorlevel 1 echo copy to %DEST% failed& exit /b 1
if not exist "%DEST%\StartAllBackX64.dll" echo StartAllBack install incomplete: StartAllBackX64.dll missing& exit /b 1
if not exist "%DEST%\StartAllBackLoaderX64.dll" echo StartAllBack install incomplete: loader missing& exit /b 1

echo StartAllBack 3.6 installed to %DEST%
exit /b 0
