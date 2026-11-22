@echo off
setlocal EnableExtensions
rem MICPE live log viewer.
rem
rem Pops up in its own console window and refreshes once a second, so the
rem bootstrap progress is visible on screen even when the desktop never
rem appears (black screen). Launch it from a PE console with:
rem     %SystemRoot%\System32\MICPE\show-log.cmd
rem The bootstrap and the authenticated session both start it automatically.

title MICPE native Administrator logon - live log
set "MICPE=%SystemRoot%\System32\MICPE"
set "B=%MICPE%\native-logon-bootstrap.log"
set "S=%MICPE%\native-logon-session.log"
set "P=X:\native-logon-probe.txt"

rem Always read the LIVE X: copies, never the published copies on disk.
rem `copy` opens its destination with no sharing, so reading the published
rem copy from this loop made every :PUBLISH fail with a sharing violation
rem ("another program is using this file"). The disk copies are still written
rem for after-the-fact inspection; this window just must not hold them open.

mode con cols=120 lines=50 >nul 2>&1
color 0F >nul 2>&1

:loop
cls
echo ==================================================================
echo   MICPE native Administrator logon  -  live log
echo ==================================================================
echo  bootstrap : %B%
echo  session   : %S%
echo  probe     : %P%
echo  now       : %date% %time%
echo ==================================================================
if exist "%B%" (
    echo  ----- SYSTEM phase - bootstrap -----
    type "%B%"
) else (
    echo  no bootstrap log yet ...
)
if exist "%P%" (
    echo.
    echo  ----- authenticated session probe -----
    type "%P%"
)
if exist "%S%" (
    echo.
    echo  ----- authenticated session log -----
    type "%S%"
)
echo.
echo ==================================================================
echo  refreshing every 2s ... close this window when done.
ping -n 3 127.0.0.1 >nul 2>&1
goto loop
