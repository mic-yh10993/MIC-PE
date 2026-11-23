-- MICPE window probe (round 8, A1; round 9, A9: WINPROBE_PREFIX).
-- Checks whether the shell windows exist and are visible. Called by
-- probe-wb2.cmd via WinXShell -script (no PowerShell in the image, so
-- window probes can only go through WinXShell Lua).
-- Writes one key=value line per line to %SystemDrive%\micpe-winprobe.txt;
-- the caller appends that file to both probe files (dual-write).
-- Round 9 (A9): WINPROBE_PREFIX (e.g. "early_", "t0_") is prepended to
-- every key, so several snapshots can live in one probe file without
-- colliding (Read-ProbeFile lets the last duplicate win). Unset means
-- plain keys (the existing late snapshot).
local drive = os.getenv("SystemDrive") or "X:"
local keyprefix = os.getenv("WINPROBE_PREFIX") or ""
local out = io.open(drive .. "/micpe-winprobe.txt", "w")
if out then
  local function emit(k, v)
    out:write(string.format("%s=%s\n", k, v))
  end
  local function probe(class, prefix)
    local w = winapi.find_window(class, nil)
    local exists = (w ~= nil and w:get_handle() ~= 0)
    local vis = false
    local pid = 0
    if exists then
      vis = w:is_visible()
      pid = w:get_pid() or 0
    end
    emit(keyprefix .. prefix .. "_exists", exists and "1" or "0")
    emit(keyprefix .. prefix .. "_visible", vis and "1" or "0")
    emit(keyprefix .. prefix .. "_pid", tostring(pid))
  end
  probe("Shell_TrayWnd", "shell_traywnd")
  probe("Progman", "progman")
  emit(keyprefix .. "screen_x", tostring(Screen:GetX()))
  emit(keyprefix .. "screen_y", tostring(Screen:GetY()))
  out:close()
end
