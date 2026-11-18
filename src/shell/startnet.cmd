@echo off
rem MICPE bootstrap (M2): PECMD desktop shell when present, cmd fallback otherwise.
rem PECMD.INI (loaded by PECMD.EXE) starts Explorer, ctfmon, the desktop
rem shortcuts and probe.cmd. When no PECMD binary was supplied with the image,
rem fall back to the M1 behaviour: run probe.cmd directly, then a prompt.
wpeinit
rem Drive letters (user decision 2026-11-17 23:43): the PE system drive stays
rem X:; the installed-Windows volume keeps C:. Fix-DriveLetters.cmd swaps
rem the letters when the boot media stole C:, and records the result in
rem %SystemDrive%\micpe-drive-letters.txt for probe.cmd. It is a no-op when
rem there is no installed Windows volume (the CI harness) or C: is already
rem the Windows volume. It never touches the PE system drive itself.
if exist "%SystemRoot%\System32\MICPE\Fix-DriveLetters.cmd" call "%SystemRoot%\System32\MICPE\Fix-DriveLetters.cmd"
if exist "%SystemDrive%\Program Files\MICPE\PECMD.EXE" (
    rem Diagnostic markers, run 44267918861: in a batch script cmd WAITS
    rem for a GUI program to exit (Microsoft Learn, start command: "This
    rem behavior doesn't occur if you run the application from a command
    rem script"), so this line blocks until PECMD.EXE finishes LOAD and
    rem startnet.cmd only reaches the wait below after the PECMD chain
    rem returns (run 44303866765). Record the launch, give the chain
    rem about 45 seconds, then run the probe from startnet as a control
    rem if PECMD's own EXEC never wrote one. probe.cmd copies the marks
    rem file into probe.txt.
    echo mark_startnet_pecmd_before=1 >> "%SystemDrive%\micpe-pecmd-marks.txt"
    "%SystemDrive%\Program Files\MICPE\PECMD.EXE" LOAD "%SystemDrive%\Program Files\MICPE\PECMD.INI"
    echo mark_startnet_after_pecmd_launch=1 >> "%SystemDrive%\micpe-pecmd-marks.txt"
    ping -n 46 127.0.0.1 >nul 2>&1
    set "MICPE_PROBE_FOUND="
    for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if exist "%%D:\micpe-probe.txt" set "MICPE_PROBE_FOUND=1"
    if not defined MICPE_PROBE_FOUND if exist "%SystemRoot%\System32\probe.cmd" call probe.cmd
) else (
    echo PECMD.EXE not found - falling back to the command shell.
    if exist "%SystemRoot%\System32\probe.cmd" call probe.cmd
)
cmd.exe
