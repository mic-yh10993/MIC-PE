@echo off
rem MICPE bootstrap for stage M1: prove the base image boots and gives us a shell.
wpeinit
echo.
echo MICPE base image OK - stage M1
echo.
rem The build injects probe.cmd next to this file; when present it writes the
rem self-check results to the QEMU share (or X:\) and shuts down, which is how
rem CI knows the boot worked. Without it the image just drops to a prompt.
if exist "%SystemRoot%\System32\probe.cmd" call probe.cmd
cmd.exe
