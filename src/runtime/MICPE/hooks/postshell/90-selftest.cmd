@echo off
rem ==========================================================================
rem  Shell self test - runs only under the QEMU/CI harness
rem
rem  The marker file micpe-selftest.flag on the first writable non-X: volume
rem  switches this test on. On real hardware no such volume exists, so the
rem  hook does nothing at all.
rem
rem  What it does, and why:
rem    1. records how many Explorer processes run (one is healthy, two is the
rem       "second shell" bug, none means the shell died)
rem    2. opens a normal folder window   -> does a shell window come up?
rem    3. opens the Recycle Bin          -> the case that never worked
rem    4. records the process list again, so the host can tell "the window
rem       opened" from "the process died"
rem
rem  Everything is written to micpe-selftest.txt on the same volume; the QEMU
rem  harness reads that file straight from the host directory.
rem ==========================================================================

set "OUT="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if not defined OUT if exist "%%D:\micpe-selftest.flag" set "OUT=%%D:\"
)
if not defined OUT goto :EOF

set "SYS32=%SystemRoot%\System32"

echo == shell self test ==>"%OUT%micpe-selftest.txt"
echo date=%DATE% %TIME%>>"%OUT%micpe-selftest.txt"
echo user=%USERNAME%>>"%OUT%micpe-selftest.txt"
echo userprofile=%USERPROFILE%>>"%OUT%micpe-selftest.txt"

echo -- processes before -->"%OUT%micpe-selftest.txt"
tasklist /fi "imagename eq explorer.exe" >>"%OUT%micpe-selftest.txt" 2>&1
tasklist /fi "imagename eq winlogon.exe" >>"%OUT%micpe-selftest.txt" 2>&1
tasklist /fi "imagename eq LogonUI.exe" >>"%OUT%micpe-selftest.txt" 2>&1
tasklist /fi "imagename eq dwm.exe" >>"%OUT%micpe-selftest.txt" 2>&1

echo -- open a folder window -->"%OUT%micpe-selftest.txt"
start "" "%SYS32%\explorer.exe" "X:\Windows"
ping -n 8 127.0.0.1 >nul 2>&1
echo -- open the recycle bin -->>"%OUT%micpe-selftest.txt"
start "" "%SYS32%\explorer.exe" "::{645FF040-5081-101B-9F08-00AA002F954E}"
ping -n 8 127.0.0.1 >nul 2>&1

echo -- processes after -->"%OUT%micpe-selftest.txt"
tasklist /fi "imagename eq explorer.exe" >>"%OUT%micpe-selftest.txt" 2>&1
tasklist /m /fi "imagename eq explorer.exe" >>"%OUT%micpe-selftest.txt" 2>&1
echo -- end -->"%OUT%micpe-selftest.txt"
goto :EOF
