@echo off
rem ---------------------------------------------------------------------------
rem MICPE drive-letter fix (user decision 2026-11-17 23:43).
rem
rem The PE system drive is X: (RAM disk). The volume holding an installed
rem Windows must keep C:; the PE boot media (USB stick / ISO) must not
rem steal it. WinPE assigns letters in enumeration order, so on a real
rem machine the boot media often lands on C: and the installed Windows
rem on D: or later. This script swaps the two letters back.
rem
rem Runs from startnet.cmd right after wpeinit, before PECMD / probe.cmd,
rem so every later step (PECMD.INI scan, probe.cmd, installer discovery)
rem sees the fixed letters. It never touches the PE system drive itself
rem (X: is the RAM disk; its letter cannot change while PE is running).
rem
rem Method (swap, not full re-enumeration): find the first non-PE volume
rem holding \Windows\System32\config\SYSTEM; if it is not already C:,
rem move it to C: with mountvol (volume GUIDs, never bare letters) and
rem give its old letter to the volume that held C:. Every other volume
rem keeps its letter. A full re-enumeration was rejected: it would move
rem the probe share and the boot media unpredictably.
rem
rem Every mountvol call below uses `call`: a bare `mountvol` from inside
rem this batch file transfers control and never returns when mountvol
rem resolves to a .cmd/.bat (the CI test fake is mountvol.cmd; run
rem 44240588434 stopped after step 1 with exactly 2 calls logged).
rem Against the real mountvol.exe `call` behaves identically and still
rem propagates errorlevel. The two `for /f ('mountvol ... /L')`
rem captures already run in a child cmd and return on their own.
rem
rem mountvol.exe comes from install.wim via src/filelists/10-cmdpe.txt
rem (same pattern as tasklist.exe, run 44135105700). The installer
rem (Deploy.ps1 / MICPE-Setup.wcs) already calls mountvol in PE, so
rem shipping it also closes that latent gap.
rem
rem Result is recorded in %SystemDrive%\micpe-drive-letters.txt
rem (pe_drive / win_drive / drive_fixed / drive_fix_error) for probe.cmd
rem to copy into the probe file. On any failure the script stops at that
rem step and records it; it never tries to roll back (a half-done swap
rem rolled back blindly could unletter a volume).
rem ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion

set "PE_DRIVE=%SystemDrive:~0,1%"
set "STATUS_FILE=%SystemDrive%\micpe-drive-letters.txt"
set "WIN_DRIVE=none"
set "DRIVE_FIXED=0"
set "DRIVE_FIX_ERROR="
set "GUID_WIN="
set "GUID_C="
set "TMP_LETTER="

rem Find the first non-PE volume that holds an installed Windows. A/B are
rem floppy letters and stay out; X: is the PE system drive and is not in
rem the list, and the PE_DRIVE check covers it anyway if it ever moves.
for %%L in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do if /i not "%%L"=="%PE_DRIVE%" if exist "%%L:\Windows\System32\config\SYSTEM" if "!WIN_DRIVE!"=="none" set "WIN_DRIVE=%%L"

rem No installed Windows found (the CI harness: only the PE RAM disk and
rem the vvfat share), or it is already C: -- nothing to do.
if "!WIN_DRIVE!"=="none" goto :write_status
if /i "!WIN_DRIVE!"=="C" goto :write_status

rem Volume GUID of the Windows volume. mountvol /L prints one line:
rem \\?\Volume{...}\ -- take the first line.
for /f "delims=" %%G in ('mountvol !WIN_DRIVE!: /L 2^>nul') do if not defined GUID_WIN set "GUID_WIN=%%G"
if not defined GUID_WIN (
    set "DRIVE_FIX_ERROR=noguid_win"
    goto :write_status
)

rem A free letter for the swap, scanned from Z: down. Must differ from C:,
rem the Windows volume's letter and the PE drive, and must have no volume.
for %%L in (Z Y W V U T S R Q P O N M L K J I H G F E D) do if not defined TMP_LETTER if /i not "%%L"=="C" if /i not "%%L"=="!WIN_DRIVE!" if /i not "%%L"=="%PE_DRIVE%" if not exist "%%L:\" set "TMP_LETTER=%%L"
if not defined TMP_LETTER (
    set "DRIVE_FIX_ERROR=no_free_letter"
    goto :write_status
)

rem Step 1: give the Windows volume the temp letter as well (a volume may
rem hold several letters), so it is never unlettered during the swap.
call mountvol !TMP_LETTER!: !GUID_WIN! >nul 2>&1
if errorlevel 1 (
    set "DRIVE_FIX_ERROR=tmp_assign"
    goto :write_status
)

rem Step 2: drop the Windows volume's old letter.
call mountvol !WIN_DRIVE!: /D >nul 2>&1
if errorlevel 1 (
    set "DRIVE_FIX_ERROR=win_unletter"
    goto :write_status
)

rem Step 3: if C: is taken, remember that volume's GUID and drop C:.
if exist "C:\" for /f "delims=" %%G in ('mountvol C: /L 2^>nul') do if not defined GUID_C set "GUID_C=%%G"
if exist "C:\" if not defined GUID_C (
    set "DRIVE_FIX_ERROR=noguid_c"
    goto :write_status
)
if exist "C:\" call mountvol C: /D >nul 2>&1
if exist "C:\" if errorlevel 1 (
    set "DRIVE_FIX_ERROR=c_unletter"
    goto :write_status
)

rem Step 4: C: now goes to the Windows volume.
call mountvol C: !GUID_WIN! >nul 2>&1
if errorlevel 1 (
    set "DRIVE_FIX_ERROR=c_assign"
    goto :write_status
)

rem Step 5: the volume that held C: takes the Windows volume's old letter.
if defined GUID_C call mountvol !WIN_DRIVE!: !GUID_C! >nul 2>&1
if defined GUID_C if errorlevel 1 (
    set "DRIVE_FIX_ERROR=win_reletter"
    goto :write_status
)

rem Step 6: drop the temp letter. If this fails the swap itself still
rem stands (C: is the Windows volume); only an extra letter lingers.
call mountvol !TMP_LETTER!: /D >nul 2>&1
if errorlevel 1 (
    set "DRIVE_FIX_ERROR=tmp_remove"
    goto :write_status
)

set "DRIVE_FIXED=1"

:write_status
> "%STATUS_FILE%" echo pe_drive=%PE_DRIVE%
>> "%STATUS_FILE%" echo win_drive=%WIN_DRIVE%
>> "%STATUS_FILE%" echo drive_fixed=%DRIVE_FIXED%
if defined DRIVE_FIX_ERROR >> "%STATUS_FILE%" echo drive_fix_error=%DRIVE_FIX_ERROR%
endlocal
exit /b 0
