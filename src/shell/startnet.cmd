@echo off
rem MICPE bootstrap (M2): PECMD desktop shell when present, cmd fallback otherwise.
rem PECMD.INI (loaded by PECMD.EXE) starts Explorer, ctfmon, the desktop
rem shortcuts and probe.cmd. When no PECMD binary was supplied with the image,
rem fall back to the M1 behaviour: run probe.cmd directly, then a prompt.
wpeinit
if exist "%SystemDrive%\Program Files\MICPE\PECMD.EXE" (
    "%SystemDrive%\Program Files\MICPE\PECMD.EXE" LOAD "%SystemDrive%\Program Files\MICPE\PECMD.INI"
) else (
    echo PECMD.EXE not found - falling back to the command shell.
    if exist "%SystemRoot%\System32\probe.cmd" call probe.cmd
)
cmd.exe
