@echo off
setlocal EnableExtensions
title MICPE local build + QEMU verify (administrator)

rem One-click local build wrapper. Double-click this file; it self-elevates
rem via UAC (the host is configured for automatic elevation) and then runs
rem the native-logon build. QEMU verification is done separately by the agent
rem after the ISO exists (the native-logon image does not emit the standard
rem probe_done marker, so the built-in -Verify would just wait and time out).

set "PWSH=C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\pwsh\pwsh.exe"
set "BUILDER=C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\MIC-PE\scripts\Invoke-LocalBuild.ps1"
set "BUILDARGS=-Workspace E:\micpe -NativeLogonExperiment -SkipDownload"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator elevation ...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"
    exit /b
)

echo Running elevated. Starting MICPE local build ...
echo.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%BUILDER%" %BUILDARGS%
set "RC=%errorlevel%"
echo.
echo ============================================================
echo Build finished with exit code %RC%.
echo Workspace: E:\micpe    ISO: E:\micpe\out\MICPE.iso
echo (Tell the agent the build is done to run QEMU verification.)
echo ============================================================
pause
