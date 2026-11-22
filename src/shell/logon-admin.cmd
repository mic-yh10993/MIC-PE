@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem MICPE post-logon initialization. This file is referenced by Userinit in
rem 25-native-logon-experiment.reg, so it runs in the AUTHENTICATED user
rem session (Administrator, RID 500) — never in the SYSTEM bootstrap session.
rem It deliberately does not invoke PECMD.EXE: the native logon path must not
rem depend on the SYSTEM-session shell.

set "LOG=%SystemRoot%\System32\MICPE\native-logon-session.log"
set "PROBE=X:\native-logon-probe.txt"

rem Locate the vvfat share exactly like src/ci/probe.cmd does: scan every
rem drive except the PE system drive (X:) for a writable volume. The QEMU
rem harness attaches the share as the first IDE disk; the guest writes the
rem evidence there and the host reads it straight from the share directory.
rem Without this the evidence stays on X: (the RAM disk) and QEMU cannot see
rem it, so a real Administrator logon would be indistinguishable from SYSTEM.
set "PROBE_DIR="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\" (
        echo test 2>nul > "%%D:\micpe-write-test.tmp"
        if exist "%%D:\micpe-write-test.tmp" (
            del "%%D:\micpe-write-test.tmp" >nul 2>&1
            if not defined PROBE_DIR set "PROBE_DIR=%%D:\"
        )
    )
)

echo [%date% %time%] authenticated user session started > "%LOG%"
echo [%date% %time%] USERNAME=%USERNAME% USERPROFILE=%USERPROFILE%>>"%LOG%"
echo [%date% %time%] USERDOMAIN=%USERDOMAIN% SESSIONNAME=%SESSIONNAME%>>"%LOG%"
whoami >>"%LOG%" 2>&1
whoami /user >>"%LOG%" 2>&1
whoami /groups >>"%LOG%" 2>&1
whoami /priv >>"%LOG%" 2>&1
echo [%date% %time%] about to start explorer: %WinDir%\explorer.exe>>"%LOG%"
if exist "%WinDir%\explorer.exe" (echo [%date% %time%] explorer.exe EXISTS>>"%LOG%") else (echo [%date% %time%] explorer.exe MISSING>>"%LOG%")

rem ---- visible evidence window ----
rem This script runs inside the authenticated session, but Userinit starts it
rem without a console. If Explorer never renders, the screen stays black and
rem there is nothing on screen to read - so pop the live log in its own window.
if exist "%SystemRoot%\System32\MICPE\show-log.cmd" (
    start "MICPE session log" "%SystemRoot%\System32\cmd.exe" /k "%SystemRoot%\System32\MICPE\show-log.cmd"
)

set "SID="
for /f "tokens=1,2" %%A in ('whoami /user /nh 2^>nul') do set "SID=%%B"

set "NON_SYSTEM=1"
whoami | find /i "nt authority\system" >nul 2>&1
if not errorlevel 1 set "NON_SYSTEM=0"

rem Machine-readable evidence for the runtime probe / CI. These keys are
rem what distinguishes a real logon from a SYSTEM-started Explorer.
>  "%PROBE%" echo native_logon=1
>> "%PROBE%" echo session_user=%USERNAME%
>> "%PROBE%" echo session_non_system=%NON_SYSTEM%
>> "%PROBE%" echo session_sid=%SID%
>> "%PROBE%" echo logon_admin_script=1

rem Publish the same evidence to the vvfat share so the QEMU host can read
rem it. X:\ is only the local mirror; without a writable share the harness
rem sees nothing. Also write a generic micpe-probe.txt so Test-Stage.ps1's
rem existing probe assertions can consume these keys unchanged.
if defined PROBE_DIR (
    >  "%PROBE_DIR%native-logon-probe.txt" echo native_logon=1
    >> "%PROBE_DIR%native-logon-probe.txt" echo session_user=%USERNAME%
    >> "%PROBE_DIR%native-logon-probe.txt" echo session_non_system=%NON_SYSTEM%
    >> "%PROBE_DIR%native-logon-probe.txt" echo session_sid=%SID%
    >> "%PROBE_DIR%native-logon-probe.txt" echo logon_admin_script=1
    copy /y "%PROBE%" "%PROBE_DIR%micpe-probe.txt" >nul 2>&1
)

rem UWP services are started again here because a few of them are triggered
rem per session and may not survive the session switch. Failures are benign.
for %%S in (TextInputManagementService SENS CoreMessagingRegistrar UserManager BrokerInfrastructure StateRepository Schedule AppReadiness) do (
    sc.exe start %%~S >>"%LOG%" 2>&1
)

rem ---- Desktop shell (the reason we got a BLACK SCREEN after logon) ----
rem In WinPE, Winlogon's own Shell=explorer.exe launch path is unreliable in
rem the freshly created interactive session. WimBuilder2's verified recipe
rem (startnet.cmd -init ADMIN / RunShell) starts the shell EXPLICITLY from the
rem authenticated session. We have no WinXShell here, so use the stock PE
rem Explorer directly. Without this block the session forms (cursor moves) but
rem no Explorer/taskbar/Start menu ever appears and SAS does nothing.
set "SHELL_STARTED=0"
if exist "%SystemRoot%\explorer.exe" (
    echo [%date% %time%] starting explorer.exe in authenticated session: "%SystemRoot%\explorer.exe">>"%LOG%"
    echo [%date% %time%] current token:>>"%LOG%"
    whoami >>"%LOG%" 2>&1
    rem Use an explicit empty title (the "" argument) so a quoted path is never
    rem misread as the window title -> "file not found" popup. Set the working
    rem directory to SystemRoot to mirror how Winlogon/Userinit launch the shell.
    pushd "%SystemRoot%"
    start "" "%SystemRoot%\explorer.exe"
    popd
    set "SHELL_STARTED=1"
) else (
    echo [%date% %time%] ERROR: explorer.exe missing; no desktop will appear>>"%LOG%"
)

rem Input method must run in the interactive session (taskbar tray icon).
if exist "%SystemRoot%\System32\ctfmon.exe" (
    pushd "%SystemRoot%\System32"
    start "" "ctfmon.exe"
    popd
)

rem ShellExperienceHost / StartMenuExperienceHost are launched by Explorer +
rem sihost on the UWP path; do not launch them directly here. Keep sihost as
rem the registered ShellInfrastructure (set in the Winlogon overlay).

echo [%date% %time%] shell_started=%SHELL_STARTED%>>"%LOG%"
echo [%date% %time%] authenticated session initialization complete>>"%LOG%"

rem DIAGNOSTIC: publish both logs to the writable share so the QEMU host can
rem see exactly how far the session got even when the desktop stays black.
if defined PROBE_DIR (
    copy /y "%LOG%" "%PROBE_DIR%native-logon-session.log" >nul 2>&1
    if exist "%SystemRoot%\System32\MICPE\native-logon-bootstrap.log" (
        copy /y "%SystemRoot%\System32\MICPE\native-logon-bootstrap.log" "%PROBE_DIR%native-logon-bootstrap.log" >nul 2>&1
    )
)
endlocal
exit /b 0
