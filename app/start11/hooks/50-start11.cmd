@echo off
rem Start11 launcher.
rem
rem app/start11/install.bat drops this file into the image as
rem   System32\MICPE\hooks\postshell\50-start11.cmd
rem so it runs after the shell is up (see src/runtime/MICPE/hooks/README.md).
rem
rem Two guards, both cheap and both silent on purpose:
rem   - no Start11 folder: this file was copied by hand, nothing to start
rem   - StartAllBack present: two shell replacers fight over the taskbar, and
rem     StartAllBack is the one this image is configured for
rem
rem Start11_64.exe is the 64-bit host; Start11.exe is only its launcher stub.

set "S11=X:\Program Files\Start11"
set "SAB=X:\Program Files\StartAllBack"

if not exist "%S11%\Start11_64.exe" goto :EOF
if exist "%SAB%\StartAllBackX64.dll" goto :EOF

>>"%MICPE%\logs\boot.log" echo [%DATE% %TIME%] hook postshell: starting Start11
start "" "%S11%\Start11_64.exe"
exit /b 0
