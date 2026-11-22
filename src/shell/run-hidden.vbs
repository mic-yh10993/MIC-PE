' MICPE post-logon launcher (v6).
'
' Winlogon's Run key cannot start a .cmd directly and a bare cmd.exe would
' paint a console window across the new desktop - the exact "黑色 cmd 窗口"
' symptom this build is trying to get rid of. The base image ships the
' script host, so launch logon-admin.cmd with a hidden window (0) and
' without waiting (False): Winlogon's logon path must never block on it.
Option Explicit

Dim shell, cmd, root
Set shell = CreateObject("WScript.Shell")
root = shell.ExpandEnvironmentStrings("%SystemRoot%")
cmd = "cmd.exe /c """ & root & "\System32\MICPE\logon-admin.cmd"""
shell.Run cmd, 0, False
