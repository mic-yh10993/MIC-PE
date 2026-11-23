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
set "TASKLIST_OUT=%SystemDrive%\micpe-tasklist.txt"
if defined PROBE_DIR set "TASKLIST_OUT=%PROBE_DIR%micpe-tasklist.txt"
> "%TASKLIST_OUT%" echo --- micpe tasklist ---

> "%PROBE_LOCAL%" echo boot=1 & > "%PROBE_OUT%" echo boot=1
>> "%PROBE_LOCAL%" echo share=%SHARE% & >> "%PROBE_OUT%" echo share=%SHARE%
if defined PROBE_DIR >> "%PROBE_LOCAL%" echo share_drive=%PROBE_DIR%
if defined PROBE_DIR >> "%PROBE_OUT%" echo share_drive=%PROBE_DIR%

>> "%PROBE_LOCAL%" echo mark_probe_start=%TIME: =0%
>> "%PROBE_OUT%" echo mark_probe_start=%TIME: =0%

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

>> "%PROBE_LOCAL%" echo mark_shell_ready=%TIME: =0%
>> "%PROBE_OUT%" echo mark_shell_ready=%TIME: =0%

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
sc.exe start Themes >nul 2>&1
set "RC_THEMES=!errorlevel!"
>> "%PROBE_OUT%" echo scstart_themes_rc=!RC_THEMES!
>> "%PROBE_LOCAL%" echo scstart_themes_rc=!RC_THEMES!

rem Start-timing re-check (round 5; not asserted). sc start returns before
rem the service finishes starting, and a service can start and then die
rem (svchost host crash, dependency loss). Wait 10 s, then re-check
rem RUNNING: rc=0 + after=1 means the manual start worked and held;
rem rc=0 + after=0 means it started and died; rc!=0 + after=0 means it
rem never started.
ping -n 11 127.0.0.1 >nul 2>&1
sc.exe query seclogon 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo seclogon_after=0 >> "%PROBE_OUT%" & echo seclogon_after=0 >> "%PROBE_LOCAL%") else (echo seclogon_after=1 >> "%PROBE_OUT%" & echo seclogon_after=1 >> "%PROBE_LOCAL%")
sc.exe query SENS 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo sens_after=0 >> "%PROBE_OUT%" & echo sens_after=0 >> "%PROBE_LOCAL%") else (echo sens_after=1 >> "%PROBE_OUT%" & echo sens_after=1 >> "%PROBE_LOCAL%")
sc.exe query Themes 2>nul | find /i "RUNNING" >nul
if errorlevel 1 (echo themes_after=0 >> "%PROBE_OUT%" & echo themes_after=0 >> "%PROBE_LOCAL%") else (echo themes_after=1 >> "%PROBE_OUT%" & echo themes_after=1 >> "%PROBE_LOCAL%")

rem Phase 25 sc-start return codes (round 5; not asserted). Phase 25 writes
rem one p25_<service>_rc=<code> line per service into scstart-rc.txt; the
rem probe copies them into the probe file so the host sees the boot-time
rem start story even when boot.log never uploads (artifact quota).
if exist "%SystemRoot%\System32\MICPE\logs\scstart-rc.txt" (
    type "%SystemRoot%\System32\MICPE\logs\scstart-rc.txt" >> "%PROBE_OUT%"
    type "%SystemRoot%\System32\MICPE\logs\scstart-rc.txt" >> "%PROBE_LOCAL%"
)

rem Phase 40 taskbar-wait timestamps (round 6; not asserted). Phase 40
rem writes taskbar_wait_start/end around the unbounded WinXShell
rem Taskbar:WaitForReady() call; the probe copies them here so the
rem wait duration is visible in the CI log even when boot.log never
rem uploads (artifact quota). Shot-02 analysis (round 6) showed the
rem r65/r66 timing flip is host speed, not a guest stall - these keys
rem let the next round prove it directly instead of inferring from
rem the vvfat warning.
if exist "%SystemRoot%\System32\MICPE\logs	askbar-wait.txt" (
    type "%SystemRoot%\System32\MICPE\logs	askbar-wait.txt" >> "%PROBE_OUT%"
    type "%SystemRoot%\System32\MICPE\logs	askbar-wait.txt" >> "%PROBE_LOCAL%"
)

rem Wallpaper diagnostics (round 5; asserted). The wallpaper file is copied
rem by the Brand step and the Wallpaper registry value is written at build
rem time (40-themes-default.reg), so a 0 here is a build regression, not a
rem runtime failure. File 1 + value 0 means the .reg import failed.
if exist "%SystemRoot%\Web\Wallpaper\Windows\img0.jpg" (echo wallpaper_file=1 >> "%PROBE_OUT%" & echo wallpaper_file=1 >> "%PROBE_LOCAL%") else (echo wallpaper_file=0 >> "%PROBE_OUT%" & echo wallpaper_file=0 >> "%PROBE_LOCAL%")
reg query "HKU\.DEFAULT\Control Panel\Desktop" /v Wallpaper 2>nul | find /i "img0.jpg" >nul
if errorlevel 1 (echo wallpaper_set=0 >> "%PROBE_OUT%" & echo wallpaper_set=0 >> "%PROBE_LOCAL%") else (echo wallpaper_set=1 >> "%PROBE_OUT%" & echo wallpaper_set=1 >> "%PROBE_LOCAL%")

rem Desktop-init values (round 5; asserted). These are build-time registry
rem values the image must carry, checked in HKU\.DEFAULT (the template hive
rem the build writes): HideDesktopIcons (This PC + Recycle Bin shown),
rem StartMenuInit (Start menu state initialised), and the taskbar values
rem (TaskbarGlomLevel=1, TaskbarMn/ShowTaskViewButton off). A 0 here is a
rem build regression - before round 5 the CI had no assertion covering the
rem desktop at all, so a black desktop with no icons passed silently.
set "ICONS_OK=1"
reg query "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" 2>nul | find /i "0x0" >nul
if errorlevel 1 set "ICONS_OK=0"
reg query "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{645FF040-5081-101B-9F08-00AA002F954E}" 2>nul | find /i "0x0" >nul
if errorlevel 1 set "ICONS_OK=0"
>> "%PROBE_OUT%" echo desktop_icons=!ICONS_OK!
>> "%PROBE_LOCAL%" echo desktop_icons=!ICONS_OK!
reg query "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v StartMenuInit 2>nul | find /i "0xd" >nul
if errorlevel 1 (echo startmenu_init=0 >> "%PROBE_OUT%" & echo startmenu_init=0 >> "%PROBE_LOCAL%") else (echo startmenu_init=1 >> "%PROBE_OUT%" & echo startmenu_init=1 >> "%PROBE_LOCAL%")
set "TB_OK=1"
reg query "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarGlomLevel 2>nul | find /i "0x1" >nul
if errorlevel 1 set "TB_OK=0"
reg query "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarMn 2>nul | find /i "0x0" >nul
if errorlevel 1 set "TB_OK=0"
reg query "HKU\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton 2>nul | find /i "0x0" >nul
if errorlevel 1 set "TB_OK=0"
>> "%PROBE_OUT%" echo taskbar_values=!TB_OK!
>> "%PROBE_LOCAL%" echo taskbar_values=!TB_OK!

rem --- service state capture (round 6; not asserted) -------------------------
rem sc query gives the full picture the RUNNING checks above cannot:
rem STATE (1 STOPPED / 2 START_PENDING / 4 RUNNING), WIN32_EXIT_CODE,
rem SERVICE_EXIT_CODE and the hosting svchost PID. r66 proved the two
rem death modes are different - Themes stuck START_PENDING (sc start
rem returns 1056, never RUNNING) vs seclogon/SENS dying after start
rem (sc start returns 0, still not RUNNING 10 s later) - and only the
rem STATE + exit codes say which mode each service is in.
rem Round 7: the round-6 version parsed `sc queryex` for all four fields
rem and every parse came back missing for all 8 services (r67), while
rem the same file's for/f over tasklist worked (svchost_count=14) and
rem sc.exe is the full binary. So STATE/exit codes now come from
rem `sc query` (the command the old _run keys already use), PID from
rem tasklist's services filter, and queryex is kept only as a diagnostic
rem (qx_lines / qx_state / qx_failed) to pin down how it fails. The raw
rem query AND queryex output are dumped to the tasklist file first
rem (run 44386689307: the parse can come back missing while the raw
rem text still tells).
rem EventLog is included: if wevtutil fails below, its STATE says whether
rem the event log service itself is down.
>> "%PROBE_LOCAL%" echo mark_svcstate_start=%TIME: =0%
>> "%PROBE_OUT%" echo mark_svcstate_start=%TIME: =0%
echo --- tasklist /svc --- >> "%TASKLIST_OUT%"
tasklist /svc >> "%TASKLIST_OUT%" 2>&1
echo --- tasklist /v --- >> "%TASKLIST_OUT%"
tasklist /v >> "%TASKLIST_OUT%" 2>&1
set "SVCHOST_COUNT="
for /f %%A in ('tasklist /fi "imagename eq svchost.exe" /nh 2^>nul ^| find /c "svchost.exe"') do set "SVCHOST_COUNT=%%A"
if defined SVCHOST_COUNT (echo svchost_count=!SVCHOST_COUNT! >> "%PROBE_OUT%" & echo svchost_count=!SVCHOST_COUNT! >> "%PROBE_LOCAL%") else (echo svchost_count=missing >> "%PROBE_OUT%" & echo svchost_count=missing >> "%PROBE_LOCAL%")
call :SVCSTATE seclogon seclogon
call :SVCSTATE SENS sens
call :SVCSTATE Themes themes
call :SVCSTATE Appinfo appinfo
call :SVCSTATE Schedule schedule
call :SVCSTATE UserManager usermgr
call :SVCSTATE ShellHWDetection shhw
call :SVCSTATE EventLog eventlog

rem Schedule needs its Tasks folder at runtime (round 6 offline finding:
rem \Windows\System32\Tasks does not exist in the r65 WIM). schedsvc may
rem create it itself on start; a 0 here with Schedule still dead says not.
if exist "%SystemRoot%\System32\Tasks" (echo tasks_folder=1 >> "%PROBE_OUT%" & echo tasks_folder=1 >> "%PROBE_LOCAL%") else (echo tasks_folder=0 >> "%PROBE_OUT%" & echo tasks_folder=0 >> "%PROBE_LOCAL%")

rem --- event log (round 6; not asserted) -------------------------------------
rem wevtutil.exe + wevtapi.dll are in the base PE image (r65 boot.wim
rem verified) and the EventLog service is Start=2, so no filelist change
rem was needed. Dump the newest 200 System events, count the Service
rem Control Manager error IDs (7000 start failed, 7009 start timeout,
rem 7023 terminated with error, 7031 terminated unexpectedly, 7034
rem terminated unexpectedly), and copy the dump to the share as
rem micpe-events.txt (build.yml uploads it). The .evtx files are copied
rem too (classic probe pattern) for offline parsing when the artifact
rem quota recovers. If wevtutil fails (EventLog down), the counts stay
rem missing and wevtutil_ok=0 says so.
set "EVT_TXT=%SystemDrive%\micpe-events.txt"
if exist "%EVT_TXT%" del "%EVT_TXT%" >nul 2>&1
set "WEVTUTIL_OK=0"
if exist "%SystemRoot%\System32\wevtutil.exe" (
    wevtutil qe System /c:200 /rd:true /f:text > "%EVT_TXT%" 2>nul
    for %%F in ("%EVT_TXT%") do if %%~zF gtr 0 set "WEVTUTIL_OK=1"
)
>> "%PROBE_OUT%" echo wevtutil_ok=!WEVTUTIL_OK!
>> "%PROBE_LOCAL%" echo wevtutil_ok=!WEVTUTIL_OK!
set "EVT_7000=missing"
set "EVT_7009=missing"
set "EVT_7023=missing"
set "EVT_7031=missing"
set "EVT_7034=missing"
if "!WEVTUTIL_OK!"=="1" for /f %%A in ('type "%EVT_TXT%" ^| find /i /c "Event ID: 7000"') do set "EVT_7000=%%A"
if "!WEVTUTIL_OK!"=="1" for /f %%A in ('type "%EVT_TXT%" ^| find /i /c "Event ID: 7009"') do set "EVT_7009=%%A"
if "!WEVTUTIL_OK!"=="1" for /f %%A in ('type "%EVT_TXT%" ^| find /i /c "Event ID: 7023"') do set "EVT_7023=%%A"
if "!WEVTUTIL_OK!"=="1" for /f %%A in ('type "%EVT_TXT%" ^| find /i /c "Event ID: 7031"') do set "EVT_7031=%%A"
if "!WEVTUTIL_OK!"=="1" for /f %%A in ('type "%EVT_TXT%" ^| find /i /c "Event ID: 7034"') do set "EVT_7034=%%A"
>> "%PROBE_OUT%" echo evt_7000=!EVT_7000!
>> "%PROBE_LOCAL%" echo evt_7000=!EVT_7000!
>> "%PROBE_OUT%" echo evt_7009=!EVT_7009!
>> "%PROBE_LOCAL%" echo evt_7009=!EVT_7009!
>> "%PROBE_OUT%" echo evt_7023=!EVT_7023!
>> "%PROBE_LOCAL%" echo evt_7023=!EVT_7023!
>> "%PROBE_OUT%" echo evt_7031=!EVT_7031!
>> "%PROBE_LOCAL%" echo evt_7031=!EVT_7031!
>> "%PROBE_OUT%" echo evt_7034=!EVT_7034!
>> "%PROBE_LOCAL%" echo evt_7034=!EVT_7034!
set "EVT_COPY=0"
if "!WEVTUTIL_OK!"=="1" if defined PROBE_DIR copy /y "%EVT_TXT%" "%PROBE_DIR%\micpe-events.txt" >nul 2>&1
if "!WEVTUTIL_OK!"=="1" if defined PROBE_DIR if exist "%PROBE_DIR%\micpe-events.txt" set "EVT_COPY=1"
>> "%PROBE_OUT%" echo evt_dump_copy=!EVT_COPY!
>> "%PROBE_LOCAL%" echo evt_dump_copy=!EVT_COPY!
set "EVTX_SYSTEM=0"
if exist "%SystemRoot%\System32\winevt\Logs\System.evtx" set "EVTX_SYSTEM=1"
>> "%PROBE_OUT%" echo evtx_system=!EVTX_SYSTEM!
>> "%PROBE_LOCAL%" echo evtx_system=!EVTX_SYSTEM!
if "!EVTX_SYSTEM!"=="1" for %%F in ("%SystemRoot%\System32\winevt\Logs\System.evtx") do echo evtx_system_size=%%~zF >> "%PROBE_OUT%"
if "!EVTX_SYSTEM!"=="1" for %%F in ("%SystemRoot%\System32\winevt\Logs\System.evtx") do echo evtx_system_size=%%~zF >> "%PROBE_LOCAL%"
set "EVTX_SYSTEM_COPY=0"
if "!EVTX_SYSTEM!"=="1" if defined PROBE_DIR copy /y "%SystemRoot%\System32\winevt\Logs\System.evtx" "%PROBE_DIR%\micpe-system.evtx" >nul 2>&1
if "!EVTX_SYSTEM!"=="1" if defined PROBE_DIR if exist "%PROBE_DIR%\micpe-system.evtx" set "EVTX_SYSTEM_COPY=1"
>> "%PROBE_OUT%" echo evtx_system_copy=!EVTX_SYSTEM_COPY!
>> "%PROBE_LOCAL%" echo evtx_system_copy=!EVTX_SYSTEM_COPY!
set "EVTX_APP=0"
if exist "%SystemRoot%\System32\winevt\Logs\Application.evtx" set "EVTX_APP=1"
>> "%PROBE_OUT%" echo evtx_app=!EVTX_APP!
>> "%PROBE_LOCAL%" echo evtx_app=!EVTX_APP!
if "!EVTX_APP!"=="1" for %%F in ("%SystemRoot%\System32\winevt\Logs\Application.evtx") do echo evtx_app_size=%%~zF >> "%PROBE_OUT%"
if "!EVTX_APP!"=="1" for %%F in ("%SystemRoot%\System32\winevt\Logs\Application.evtx") do echo evtx_app_size=%%~zF >> "%PROBE_LOCAL%"
set "EVTX_APP_COPY=0"
if "!EVTX_APP!"=="1" if defined PROBE_DIR copy /y "%SystemRoot%\System32\winevt\Logs\Application.evtx" "%PROBE_DIR%\micpe-application.evtx" >nul 2>&1
if "!EVTX_APP!"=="1" if defined PROBE_DIR if exist "%PROBE_DIR%\micpe-application.evtx" set "EVTX_APP_COPY=1"
>> "%PROBE_OUT%" echo evtx_app_copy=!EVTX_APP_COPY!
>> "%PROBE_LOCAL%" echo evtx_app_copy=!EVTX_APP_COPY!

rem -- boot.log to the share (round 3) ---------------------------------------
rem Phase 25 logs every sc start return code and the seclogon poll result
rem into boot.log; the probe file alone cannot say WHY a service failed.
rem Copy it to the share so the host can read the service start story.
if defined PROBE_DIR if exist "%SystemRoot%\System32\MICPE\logs\boot.log" copy /y "%SystemRoot%\System32\MICPE\logs\boot.log" "%PROBE_DIR%\micpe-boot.log" >nul 2>&1

rem --- done ------------------------------------------------------------------
rem No shutdown: the harness takes the final screenshot, then quits QEMU.
rem probe_done goes to the local file FIRST, then the share (run 48 fix),
rem and the local copy is refreshed by a detached copy, never a share append.
>> "%PROBE_LOCAL%" echo mark_probe_end=%TIME: =0%
>> "%PROBE_OUT%" echo mark_probe_end=%TIME: =0%
>> "%PROBE_LOCAL%" echo probe_done=1
>> "%PROBE_OUT%" echo probe_done=1
if defined PROBE_DIR start "" /min cmd /c copy /y "%PROBE_LOCAL%" "%PROBE_DIR%micpe-probe-local.txt" >nul 2>&1

endlocal
exit /b 0

rem --- :SVCSTATE ---------------------------------------------------------------
rem Round 6/7: capture the full sc query picture for one service.
rem %1 = service name (as sc knows it), %2 = probe key prefix.
rem Emits 8 keys: <prefix>_state (numeric code + text, e.g. 1_STOPPED),
rem <prefix>_win32exit, <prefix>_svcexit, <prefix>_pid, <prefix>_pid_alive,
rem <prefix>_qx_lines, <prefix>_qx_state, <prefix>_qx_failed.
rem STATE and the exit codes come from `sc query` (proven: the old _run keys
rem use it); PID comes from tasklist's services filter. queryex is only a
rem diagnostic now: qx_lines counts its stdout lines, qx_state counts its
rem STATE lines, qx_failed says whether its merged output contains FAILED.
rem The raw query and queryex output are both dumped to the tasklist file
rem first: run 44386689307 proved the parse can come back missing while the
rem raw text still says what happened. pid_alive is na when the service is
rem STOPPED (PID 0) and missing when neither tasklist nor queryex found a PID.
:SVCSTATE
echo --- sc query %1 --- >> "%TASKLIST_OUT%"
sc.exe query %1 >> "%TASKLIST_OUT%" 2>&1
echo --- sc queryex %1 --- >> "%TASKLIST_OUT%"
sc.exe queryex %1 >> "%TASKLIST_OUT%" 2>&1
set "SVC_STATE="
for /f "tokens=3,4" %%A in ('sc.exe query %1 2^>nul ^| find /i "STATE"') do set "SVC_STATE=%%A_%%B"
if defined SVC_STATE (echo %2_state=!SVC_STATE! >> "%PROBE_OUT%" & echo %2_state=!SVC_STATE! >> "%PROBE_LOCAL%") else (echo %2_state=missing >> "%PROBE_OUT%" & echo %2_state=missing >> "%PROBE_LOCAL%")
set "SVC_WIN32="
for /f "tokens=3" %%A in ('sc.exe query %1 2^>nul ^| find /i "WIN32_EXIT_CODE"') do set "SVC_WIN32=%%A"
if defined SVC_WIN32 (echo %2_win32exit=!SVC_WIN32! >> "%PROBE_OUT%" & echo %2_win32exit=!SVC_WIN32! >> "%PROBE_LOCAL%") else (echo %2_win32exit=missing >> "%PROBE_OUT%" & echo %2_win32exit=missing >> "%PROBE_LOCAL%")
set "SVC_EXIT="
for /f "tokens=3" %%A in ('sc.exe query %1 2^>nul ^| find /i "SERVICE_EXIT_CODE"') do set "SVC_EXIT=%%A"
if defined SVC_EXIT (echo %2_svcexit=!SVC_EXIT! >> "%PROBE_OUT%" & echo %2_svcexit=!SVC_EXIT! >> "%PROBE_LOCAL%") else (echo %2_svcexit=missing >> "%PROBE_OUT%" & echo %2_svcexit=missing >> "%PROBE_LOCAL%")
set "SVC_PID="
for /f "tokens=2" %%A in ('tasklist /fi "services eq %1" /nh 2^>nul ^| find /i "svchost.exe"') do set "SVC_PID=%%A"
if not defined SVC_PID if "!SVC_STATE!"=="1_STOPPED" set "SVC_PID=0"
if defined SVC_PID (echo %2_pid=!SVC_PID! >> "%PROBE_OUT%" & echo %2_pid=!SVC_PID! >> "%PROBE_LOCAL%") else (echo %2_pid=missing >> "%PROBE_OUT%" & echo %2_pid=missing >> "%PROBE_LOCAL%")
set "SVC_ALIVE=missing"
if not defined SVC_PID goto :SVCSTATE_ALIVE_DONE
set "SVC_ALIVE=na"
if "!SVC_PID!"=="0" goto :SVCSTATE_ALIVE_DONE
tasklist /fi "pid eq !SVC_PID!" /nh 2>nul | find /i "svchost.exe" >nul
if errorlevel 1 (set "SVC_ALIVE=0") else (set "SVC_ALIVE=1")
:SVCSTATE_ALIVE_DONE
>> "%PROBE_OUT%" echo %2_pid_alive=!SVC_ALIVE!
>> "%PROBE_LOCAL%" echo %2_pid_alive=!SVC_ALIVE!
set "SVC_QXL="
for /f %%A in ('sc.exe queryex %1 2^>nul ^| find /c /v "zzzqqq"') do set "SVC_QXL=%%A"
if defined SVC_QXL (echo %2_qx_lines=!SVC_QXL! >> "%PROBE_OUT%" & echo %2_qx_lines=!SVC_QXL! >> "%PROBE_LOCAL%") else (echo %2_qx_lines=missing >> "%PROBE_OUT%" & echo %2_qx_lines=missing >> "%PROBE_LOCAL%")
set "SVC_QXS="
for /f %%A in ('sc.exe queryex %1 2^>nul ^| find /i /c "STATE"') do set "SVC_QXS=%%A"
if defined SVC_QXS (echo %2_qx_state=!SVC_QXS! >> "%PROBE_OUT%" & echo %2_qx_state=!SVC_QXS! >> "%PROBE_LOCAL%") else (echo %2_qx_state=missing >> "%PROBE_OUT%" & echo %2_qx_state=missing >> "%PROBE_LOCAL%")
set "SVC_QXF=0"
sc.exe queryex %1 2>&1 | find /i "FAILED" >nul
if not errorlevel 1 set "SVC_QXF=1"
>> "%PROBE_OUT%" echo %2_qx_failed=!SVC_QXF!
>> "%PROBE_LOCAL%" echo %2_qx_failed=!SVC_QXF!
goto :EOF
