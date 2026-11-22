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
rem
rem Every key is written to BOTH the local file (X:\micpe-probe-local.txt)
rem and the share file (micpe-probe.txt). Run 62 (r62) lost every key after
rem dwm=1 because the vvfat share view stalled and the share-only keys had
rem no second copy; the classic probe.cmd learned this lesson in run 47/48
rem (dual-write + Merge-ProbeFiles) and this probe now follows it. The
rem local copy is refreshed to the share at the end, so the host merge
rem recovers the full result even when the share appends stall.
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
if errorlevel 1 (echo explorer=0 >> "%PROBE_OUT%" & echo explorer=0 >> "%PROBE_LOCAL%") else (echo explorer=1 >> "%PROBE_OUT%" & echo explorer=1 >> "%PROBE_LOCAL%")

tasklist /fi "imagename eq dwm.exe" /nh 2>nul | find /i "dwm.exe" >nul
if errorlevel 1 (echo dwm=0 >> "%PROBE_OUT%" & echo dwm=0 >> "%PROBE_LOCAL%") else (echo dwm=1 >> "%PROBE_OUT%" & echo dwm=1 >> "%PROBE_LOCAL%")

rem The shell counts as ready only after it survives a settle period;
rem a crash-on-start explorer still appears in tasklist for a second or two.
ping -n 16 127.0.0.1 >nul 2>&1
tasklist /fi "imagename eq explorer.exe" /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo shell_ready=0 >> "%PROBE_OUT%" & echo shell_ready=0 >> "%PROBE_LOCAL%") else (echo shell_ready=1 >> "%PROBE_OUT%" & echo shell_ready=1 >> "%PROBE_LOCAL%")

rem --- wb2-specific ----------------------------------------------------------
rem logon_token: phase 25 wrote the flag when runas started explorer under
rem the Administrator logon token. 0 means the shell is running as SYSTEM.
if exist "%SystemRoot%\System32\MICPE\logs\logon-token.flag" (echo logon_token=1 >> "%PROBE_OUT%" & echo logon_token=1 >> "%PROBE_LOCAL%") else (echo logon_token=0 >> "%PROBE_OUT%" & echo logon_token=0 >> "%PROBE_LOCAL%")

rem sab_mapped: StartAllBackLoaderX64.dll mapped into the explorer process.
rem tasklist /m lists the processes that loaded the named module; an empty
rem result means StartAllBack never hooked explorer.
tasklist /m StartAllBackLoaderX64.dll /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo sab_mapped=0 >> "%PROBE_OUT%" & echo sab_mapped=0 >> "%PROBE_LOCAL%") else (echo sab_mapped=1 >> "%PROBE_OUT%" & echo sab_mapped=1 >> "%PROBE_LOCAL%")

rem SAB diagnostics (not asserted; they say WHY sab_mapped is 0).
rem sab_files: the loader DLL exists on disk. sab_clsid: the loader CLSID
rem is registered and points at the loader DLL. files=1 + clsid=0 means
rem the .reg import failed; both 1 + sab_mapped=0 means the
rem Drive FolderExtension was never triggered (no Drive namespace
rem creation at startup) or the DLL failed to load.
if exist "%ProgramFiles%\StartAllBack\StartAllBackLoaderX64.dll" (echo sab_files=1 >> "%PROBE_OUT%" & echo sab_files=1 >> "%PROBE_LOCAL%") else (echo sab_files=0 >> "%PROBE_OUT%" & echo sab_files=0 >> "%PROBE_LOCAL%")
reg query "HKLM\SOFTWARE\Classes\CLSID\{117E3954-5034-453A-A18B-7B79493646E6}\InProcServer32" /ve 2>nul | find /i "StartAllBackLoaderX64.dll" >nul
if errorlevel 1 (echo sab_clsid=0 >> "%PROBE_OUT%" & echo sab_clsid=0 >> "%PROBE_LOCAL%") else (echo sab_clsid=1 >> "%PROBE_OUT%" & echo sab_clsid=1 >> "%PROBE_LOCAL%")

rem sab_hook: the main StartAllBack hook DLL mapped into explorer. The
rem loader can be mapped (sab_mapped=1) while the hook DLL failed to load
rem or unloaded itself (DllCanUnloadNow); that split means the hook layer,
rem not the trigger, is broken.
tasklist /m StartAllBackX64.dll /nh 2>nul | find /i "explorer.exe" >nul
if errorlevel 1 (echo sab_hook=0 >> "%PROBE_OUT%" & echo sab_hook=0 >> "%PROBE_LOCAL%") else (echo sab_hook=1 >> "%PROBE_OUT%" & echo sab_hook=1 >> "%PROBE_LOCAL%")

rem logonui: LogonUI.exe present in the image (72-logon-ui.txt).
if exist "%SystemRoot%\System32\LogonUI.exe" (echo logonui=1 >> "%PROBE_OUT%" & echo logonui=1 >> "%PROBE_LOCAL%") else (echo logonui=0 >> "%PROBE_OUT%" & echo logonui=0 >> "%PROBE_LOCAL%")

rem seclogon: Secondary Logon service RUNNING (phase 25 starts it).
sc.exe query seclogon 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo seclogon=0 >> "%PROBE_OUT%" & echo seclogon=0 >> "%PROBE_LOCAL%") else (echo seclogon=1 >> "%PROBE_OUT%" & echo seclogon=1 >> "%PROBE_LOCAL%")

rem seclogon diagnostics (not asserted; they say WHY seclogon is 0).
rem seclogon_key: the service key exists with an svchost ImagePath.
rem seclogon_dll: the DLL is on disk. seclogon_netsvcs: netsvcs lists
rem seclogon. All three 1 + seclogon=0 means the definition is fine but
rem sc start failed at runtime - read micpe-boot.log for the return code.
reg query "HKLM\SYSTEM\CurrentControlSet\Services\seclogon" /v ImagePath 2>nul | find /i "svchost" >nul
if errorlevel 1 (echo seclogon_key=0 >> "%PROBE_OUT%" & echo seclogon_key=0 >> "%PROBE_LOCAL%") else (echo seclogon_key=1 >> "%PROBE_OUT%" & echo seclogon_key=1 >> "%PROBE_LOCAL%")
if exist "%SystemRoot%\System32\seclogon.dll" (echo seclogon_dll=1 >> "%PROBE_OUT%" & echo seclogon_dll=1 >> "%PROBE_LOCAL%") else (echo seclogon_dll=0 >> "%PROBE_OUT%" & echo seclogon_dll=0 >> "%PROBE_LOCAL%")
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" /v netsvcs 2>nul | find /i "seclogon" >nul
if errorlevel 1 (echo seclogon_netsvcs=0 >> "%PROBE_OUT%" & echo seclogon_netsvcs=0 >> "%PROBE_LOCAL%") else (echo seclogon_netsvcs=1 >> "%PROBE_OUT%" & echo seclogon_netsvcs=1 >> "%PROBE_LOCAL%")

rem Companion services (not asserted; they say whether the start failure
rem is seclogon-specific or hits every service phase 25 starts).
sc.exe query SENS 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo sens_run=0 >> "%PROBE_OUT%" & echo sens_run=0 >> "%PROBE_LOCAL%") else (echo sens_run=1 >> "%PROBE_OUT%" & echo sens_run=1 >> "%PROBE_LOCAL%")
sc.exe query Appinfo 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo appinfo_run=0 >> "%PROBE_OUT%" & echo appinfo_run=0 >> "%PROBE_LOCAL%") else (echo appinfo_run=1 >> "%PROBE_OUT%" & echo appinfo_run=1 >> "%PROBE_LOCAL%")
sc.exe query Schedule 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo schedule_run=0 >> "%PROBE_OUT%" & echo schedule_run=0 >> "%PROBE_LOCAL%") else (echo schedule_run=1 >> "%PROBE_OUT%" & echo schedule_run=1 >> "%PROBE_LOCAL%")

rem Base netsvcs services (round 4; not asserted). If UserManager, Themes
rem and ShellHWDetection are also 0, the netsvcs svchost host itself is not
rem starting services and the problem is not the four logon service
rem definitions. Themes needs the round-4 netsvcs group fix (63 .reg) to
rem start at all; UserManager and ShellHWDetection were already members.
sc.exe query UserManager 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo usermgr_run=0 >> "%PROBE_OUT%" & echo usermgr_run=0 >> "%PROBE_LOCAL%") else (echo usermgr_run=1 >> "%PROBE_OUT%" & echo usermgr_run=1 >> "%PROBE_LOCAL%")
sc.exe query Themes 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo themes_run=0 >> "%PROBE_OUT%" & echo themes_run=0 >> "%PROBE_LOCAL%") else (echo themes_run=1 >> "%PROBE_OUT%" & echo themes_run=1 >> "%PROBE_LOCAL%")
sc.exe query ShellHWDetection 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo shhw_run=0 >> "%PROBE_OUT%" & echo shhw_run=0 >> "%PROBE_LOCAL%") else (echo shhw_run=1 >> "%PROBE_OUT%" & echo shhw_run=1 >> "%PROBE_LOCAL%")

rem sc-start return codes (round 4; not asserted). These run AFTER the
rem RUNNING checks above so the assertion keys reflect the state at probe
rem time, not after this manual start. The code says WHY a STOPPED service
rem did not come up: 0 started now, 1056 already running, 1058 disabled,
rem 1083 service not in the svchost group, 1068/1075 dependency failure,
rem 2/3 file not found. The code is captured into a variable first because
rem echo itself resets errorlevel.
sc.exe start seclogon >nul 2>&1
set "RC_SECLOGON=!errorlevel!"
>> "%PROBE_OUT%" echo scstart_seclogon_rc=!RC_SECLOGON!
>> "%PROBE_LOCAL%" echo scstart_seclogon_rc=!RC_SECLOGON!
sc.exe start SENS >nul 2>&1
set "RC_SENS=!errorlevel!"
>> "%PROBE_OUT%" echo scstart_sens_rc=!RC_SENS!
>> "%PROBE_LOCAL%" echo scstart_sens_rc=!RC_SENS!

rem -- boot.log to the share (round 3) ---------------------------------------
rem Phase 25 logs every sc start return code and the seclogon poll result
rem into boot.log; the probe file alone cannot say WHY a service failed.
rem Copy it to the share so the host can read the service start story.
if defined PROBE_DIR if exist "%SystemRoot%\System32\MICPE\logs\boot.log" copy /y "%SystemRoot%\System32\MICPE\logs\boot.log" "%PROBE_DIR%\micpe-boot.log" >nul 2>&1

rem --- done ------------------------------------------------------------------
rem No shutdown: the harness takes the final screenshot, then quits QEMU.
rem probe_done goes to the local file FIRST, then the share (run 48 fix),
rem and the local copy is refreshed by a detached copy, never a share append.
>> "%PROBE_LOCAL%" echo probe_done=1
>> "%PROBE_OUT%" echo probe_done=1
if defined PROBE_DIR start "" /min cmd /c copy /y "%PROBE_LOCAL%" "%PROBE_DIR%micpe-probe-local.txt" >nul 2>&1

endlocal
exit /b 0
