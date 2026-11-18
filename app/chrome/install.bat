@echo off
rem Chrome integration (packaging round): runs in CI against a mounted boot.wim.
rem It NEVER runs inside the PE: do not install software from inside PE,
rem that wastes performance. The PE only contains the files this script
rem already integrated: copy files, write registry, done.
rem
rem Called by the M5 payload step as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem %1 = mounted image root (e.g. D:\micpe\mount)
rem %2 = repo root
rem The slimmed archive (chrome-slim.7z) is staged next to this script by
rem the payload step. It was built from the Chrome Enterprise MSI (see
rem app/chrome/README.md): Locales pruned to en-US + zh-CN, WidevineCdm
rem (DRM plugin) removed. There is no MSI install step anymore.
rem Must be idempotent and exit 0 on success, non-zero on failure.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2
set "ARCHIVE=%~dp0chrome-slim.7z"
if not exist "%ARCHIVE%" echo chrome archive not staged next to install.bat: %ARCHIVE%& exit /b 2

rem The archive's top level is Chrome-bin\, which is the Application tree
rem (chrome.exe at its root, the version dir below). Extract it, then copy
rem it into place as Application\.
set "DEST=%MOUNT%\Program Files\Google\Chrome"
if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%\Application"
set "TMP=%TEMP%\micpe-chrome-%RANDOM%"
mkdir "%TMP%"
7z x "%ARCHIVE%" "-o%TMP%" -y
if errorlevel 1 echo 7z extract failed& exit /b 1
if not exist "%TMP%\Chrome-bin\chrome.exe" echo chrome extract incomplete: chrome.exe missing& exit /b 1
xcopy "%TMP%\Chrome-bin\*" "%DEST%\Application\" /e /h /q /y
if errorlevel 1 echo copy to Application failed& exit /b 1
rmdir /s /q "%TMP%"
if not exist "%DEST%\Application\chrome.exe" echo chrome install incomplete: chrome.exe missing& exit /b 1

echo chrome installed.
exit /b 0
