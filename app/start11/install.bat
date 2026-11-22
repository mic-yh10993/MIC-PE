@echo off
rem Start11 1.3 (Stardock) integration - runs in CI against a mounted boot.wim.
rem It never runs inside the PE.
rem
rem Called by the UWP chain as:
rem   install.bat <mounted boot.wim dir> <repo root>
rem
rem Target layout is Start11's own: X:\Program Files\Start11. The hook
rem System32\MICPE\hooks\postshell\50-start11.cmd starts Start11_64.exe when
rem this folder exists and StartAllBack is not installed. Two shell replacers
rem in one image fight over the taskbar, so StartAllBack wins by default.
rem
rem Idempotent: the destination is wiped first. Exit 0 on success.
setlocal
set "MOUNT=%~1"
set "REPO=%~2"
if "%MOUNT%"=="" echo usage: install.bat ^<mount-dir^> ^<repo-root^>& exit /b 2
if not exist "%MOUNT%\Windows\System32" echo mount dir does not look like a Windows image: %MOUNT%& exit /b 2

set "SRC=%~dp0files"
set "DEST=%MOUNT%\Program Files\Start11"
if not exist "%SRC%\Start11_64.exe" echo Start11 payload missing: %SRC%\Start11_64.exe& exit /b 2

if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"
xcopy "%SRC%\*" "%DEST%\" /e /h /i /q /y >nul
if errorlevel 1 echo copy to %DEST% failed& exit /b 1
if not exist "%DEST%\Start11_64.exe" echo Start11 install incomplete: Start11_64.exe missing& exit /b 1
if not exist "%DEST%\Start10Shell64.dll" echo Start11 install incomplete: Start10Shell64.dll missing& exit /b 1

rem Start11 is a process, not a registry hook: without something starting it
rem nothing appears. Ship the launcher as a boot hook so the activation is
rem visible in the same tree as the rest of the boot chain.
set "HOOKDIR=%MOUNT%\Windows\System32\MICPE\hooks\postshell"
if not exist "%HOOKDIR%" mkdir "%HOOKDIR%"
copy /y "%~dp0hooks\50-start11.cmd" "%HOOKDIR%\50-start11.cmd" >nul
if errorlevel 1 echo could not install the Start11 boot hook& exit /b 1

echo Start11 1.3 installed to %DEST%
exit /b 0
