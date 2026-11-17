@echo off
rem Chrome integration (M5): runs in CI against a mounted boot.wim.
rem It NEVER runs inside the PE: do not install software from inside PE,
rem that wastes performance. The PE only contains the files this script
rem already integrated: copy files, write registry, done.
rem
rem Called by the M5 payload step as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem %1 = mounted image root (e.g. D:\micpe\mount)
rem %2 = repo root
rem The MSI is staged next to this script by the payload step.
rem Must be idempotent and exit 0 on success, non-zero on failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2
set "MSI=%~dp0googlechromestandaloneenterprise64.msi"
if not exist "%MSI%" echo chrome MSI not staged next to install.bat: %MSI%& exit /b 2

rem Vendor layout, not Program Files\MICPE: the admin install extracts
rem the MSI's own directory tree (Google\Chrome\...). Keep it, so Chrome
rem finds its own files where it expects them.
set "DEST=%MOUNT%\Program Files\Google\Chrome"
if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"

rem Administrative install: unpack the MSI without installing it.
rem NOTE (unverified on Windows): msiexec /a layout inside TARGETDIR is
rem not pinned here; Assert-PayloadInstalled searches recursively for
rem chrome.exe under Program Files\Google\Chrome instead.
msiexec /a "%MSI%" /qn TARGETDIR="%DEST%"
if errorlevel 1 echo msiexec admin install failed& exit /b 1

echo chrome installed.
exit /b 0
