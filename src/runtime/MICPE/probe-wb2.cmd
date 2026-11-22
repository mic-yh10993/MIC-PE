@echo off
rem ---------------------------------------------------------------------------
rem MICPE wb2 (WimBuilder2 UWP chain) in-PE self check.
rem
rem Minimal probe for the wb2 stage. The wb2 startnet never installs the
rem classic probe.cmd (no PECMD), so this runs as a postshell hook
rem (hooks/postshell/10-probe.cmd) after the shell is up. It writes the
rem same micpe-probe.txt key=value format the host asserts.
rem
rem Differences from probe.cmd:
rem  - No shutdown at the end: the harness takes the final screenshot
rem    first, then quits QEMU itself. Shutting down would leave the
rem    final screenshot black.
rem  - No UWP launch / installer / payload sections: the wb2 stage
rem    asserts only the desktop (explorer, dwm, shell_ready) plus the
rem    wb2-specific keys (logon_token, sab_mapped, logonui, seclogon).
rem ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion

rem Share scan (same as probe.cmd): first writable drive wins. The CI
rem harness attaches the vvfat share as the first IDE hard disk, which
rem WinPE letters C:; the boot ISO (optical) is D: and read-only.
set "PROBE_DIR="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:" (
        echo test 2>nul > "%%D:\micpe-write-test.tmp"
        if exist "%%D:\micpe-write-test.tmp" (
            del "%%D:\micpe-write-test.tmp" >nul 2>&1
            if not defined PROBE_DIR set "PROBE_DIR=%%D:"
        )
    )
)

if not defined PROBE_DIR (
    set "PROBE_OUT=X:\micpe-probe.txt"
    set "SHARE=0"
) else (
    set "PROBE_OUT=%PROBE_DIR%micpe-probe.txt"
    set "SHARE=1"
)

set "PROBE_LOCAL=%SystemDrive%\micpe-probe-local.txt"

> "%PROBE_LOCAL%" echo boot=1 & > "%PROBE_OUT%" echo boot=1
>> "%PROBE_LOCAL%" echo share=%SHARE% & >> "%PROBE_OUT%" echo share=%SHARE%
if defined PROBE_DIR >> "%PROBE_LOCAL%" echo share_drive=%PROBE_DIR%
if defined PROBE_DIR >> "%PROBE_OUT%" echo share_drive=%PROBE_DIR%

rem --- shell -----------------------------------------------------------------
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo explorer=0 >> "%PROBE_OUT%") else (echo explorer=1 >> "%PROBE_OUT%")

tasklist /fi "imagename eq dwm.exe" /nh 2>nul | find /i "dwm.exe" >nul
if errorlevel 1 (echo dwm=0 >> "%PROBE_OUT%") else (echo dwm=1 >> "%PROBE_OUT%")

rem The shell counts as ready only after it survives a settle period;
rem a crash-on-start explorer still appears in tasklist for a second or two.
ping -n 16 127.0.0.1 >nul 2>&1
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo shell_ready=0 >> "%PROBE_OUT%") else (echo shell_ready=1 >> "%PROBE_OUT%")

rem --- wb2-specific ----------------------------------------------------------
rem logon_token: phase 25 wrote the flag when runas started explorer under
rem the Administrator logon token. 0 means the shell is running as SYSTEM.
if exist "%SystemRoot%\System32\MICPE\logs\logon-token.flag" (echo logon_token=1 >> "%PROBE_OUT%") else (echo logon_token=0 >> "%PROBE_OUT%")

rem sab_mapped: StartAllBackLoaderX64.dll mapped into the explorer process.
rem tasklist /m lists the processes that loaded the named module; an empty
rem result means StartAllBack never hooked explorer.
tasklist /m StartAllBackLoaderX64.dll /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo sab_mapped=0 >> "%PROBE_OUT%") else (echo sab_mapped=1 >> "%PROBE_OUT%")

rem logonui: LogonUI.exe present in the image (72-logon-ui.txt).
if exist "%SystemRoot%\System32\LogonUI.exe" (echo logonui=1 >> "%PROBE_OUT%") else (echo logonui=0 >> "%PROBE_OUT%")

rem seclogon: Secondary Logon service RUNNING (phase 25 starts it).
sc.exe query seclogon 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo seclogon=0 >> "%PROBE_OUT%") else (echo seclogon=1 >> "%PROBE_OUT%")

rem --- done ------------------------------------------------------------------
rem No shutdown: the harness takes the final screenshot, then quits QEMU.
rem probe_done goes to the local file FIRST, then the share (run 48 fix),
rem and the local copy is refreshed by a detached copy, never a share append.
>> "%PROBE_LOCAL%" echo probe_done=1
>> "%PROBE_OUT%" echo probe_done=1
if defined PROBE_DIR start "" /min cmd /c copy /y "%PROBE_LOCAL%" "%PROBE_DIR%micpe-probe-local.txt" >nul 2>&1

endlocal
exit /b 0
