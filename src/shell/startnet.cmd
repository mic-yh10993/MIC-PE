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
    "%SystemDrive%\Program Files\MICPE\PECMD.EXE" LOAD "%SystemDrive%\Program Files\MICPE\PECMD.INI"
) else (
    echo PECMD.EXE not found - falling back to the command shell.
    if exist "%SystemRoot%\System32\probe.cmd" call probe.cmd
)
cmd.exe
