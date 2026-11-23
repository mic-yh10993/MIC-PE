-- MICPE window probe (round 8, A1).
-- Checks whether the shell windows exist and are visible. Called by
-- probe-wb2.cmd via WinXShell -script (no PowerShell in the image, so
-- window probes can only go through WinXShell Lua).
-- Writes one key=value line per line to %SystemDrive%\micpe-winprobe.txt;
-- the caller appends that file to both probe files (dual-write).
local drive = os.getenv("SystemDrive") or "X:"
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
    emit(prefix .. "_exists", exists and "1" or "0")
    emit(prefix .. "_visible", vis and "1" or "0")
    emit(prefix .. "_pid", tostring(pid))
  end
  probe("Shell_TrayWnd", "shell_traywnd")
  probe("Progman", "progman")
  emit("screen_x", tostring(Screen:GetX()))
  emit("screen_y", tostring(Screen:GetY()))
  out:close()
end
