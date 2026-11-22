@echo off
rem ==========================================================================
rem  Phase 20 - pre-shell environment
rem
rem  Boot runs as SYSTEM in session 0 of a RAM disk, so there is no logon and
rem  nothing has created a profile. Explorer still expects the four classic
rem  variables, and a UWP image needs the text-input process up before the
rem  shell loads or the language bar never appears:
rem
rem      USERPROFILE  X:\Users\Default
rem      Desktop      %USERPROFILE%\Desktop
rem      Programs     ...\Start Menu\Programs
rem      ctfmon.exe   input method host, started detached
rem
rem  Variables are set in the caller's scope (no setlocal) because
rem  30-runshell.cmd and explorer.exe inherit them.
rem
rem  hooks\preshell\*.cmd runs last, name order, for your own additions.
rem ==========================================================================

set "LOG=%MICPE%\logs\boot.log"

set "USERPROFILE=X:\Users\Default"
set "Desktop=%USERPROFILE%\Desktop"
set "Programs=%USERPROFILE%\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
set "APPDATA=%USERPROFILE%\AppData\Roaming"
set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
set "TEMP=%USERPROFILE%\AppData\Local\Temp"
set "TMP=%TEMP%"

call :LOG "phase 20-preshell: USERPROFILE=%USERPROFILE%"
if not exist "%TEMP%" md "%TEMP%" >nul 2>&1
if not exist "%Desktop%" md "%Desktop%" >nul 2>&1

rem -- desktop shortcuts (round 3: Command Prompt; round 5: Explorer) -------
rem A .lnk on the desktop makes Explorer parse it at desktop init, which
rem binds the X: drive namespace and triggers the Drive FolderExtension -
rem the earliest reliable trigger for the StartAllBack loader. The .lnk
rem files ship in the runtime tree and are placed here, before the shell
rem starts. Two shortcuts (Explorer + Command Prompt) match the wb2
rem _CustomDesktopItems.bat desktop set.
if exist "%MICPE%\Command Prompt.lnk" copy /y "%MICPE%\Command Prompt.lnk" "%Desktop%\Command Prompt.lnk" >nul 2>&1
if exist "%MICPE%\Explorer.lnk" copy /y "%MICPE%\Explorer.lnk" "%Desktop%\Explorer.lnk" >nul 2>&1
if exist "%Desktop%\Command Prompt.lnk" call :LOG "desktop shortcut placed: Command Prompt"
if exist "%Desktop%\Explorer.lnk" call :LOG "desktop shortcut placed: Explorer"

rem -- input method host ------------------------------------------------------
rem  DISABLED on purpose (user request 2026-11-22): starting ctfmon.exe in the
rem  PE session left the keyboard unusable - no key reached the shell at all.
rem  The input method is not needed to type, so it stays off until the shell
rem  is proven to survive it. Re-enable by removing the "rem" prefixes below.
rem
rem if exist "%SystemRoot%\System32\ctfmon.exe" (
rem     start "ctfmon" "%SystemRoot%\System32\ctfmon.exe"
rem     call :LOG "ctfmon started"
rem ) else (
rem     call :LOG "ctfmon.exe missing - the language bar will not appear"
rem )
call :LOG "ctfmon not started (disabled on purpose - see the comment above)"

call :HOOKS preshell

call :LOG "phase 20-preshell: end"
goto :EOF

:HOOKS
if not exist "%MICPE%\hooks\%~1\*.cmd" goto :EOF
for %%F in ("%MICPE%\hooks\%~1\*.cmd") do (
    call :LOG "hook %~1: %%~nxF"
    call "%%~fF"
)
goto :EOF

:LOG
>>"%LOG%" echo [%DATE% %TIME%] %~1
goto :EOF
