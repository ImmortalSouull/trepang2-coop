# Send input to a game window.
#   key.ps1 -ProcId <pid> -Vk 0x57 -HoldMs 1500      hold a key
#   key.ps1 -ProcId <pid> -Click -HoldMs 300           left mouse button (fire) at window centre
# -Focus brings the window to the foreground first (Unreal ignores input while unfocused).
#   key.ps1 -ProcId <pid> -Click -X 200 -Y 150          click at a point of the window's client area
#     (moves the real cursor there: Slate hover uses the real cursor position)
param([int]$ProcId, [int]$Vk = 0, [switch]$Click, [int]$HoldMs = 80, [switch]$Focus, [int]$X = 640, [int]$Y = 360)
if (-not ("PMK" -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices;
public class PMK {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref PT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@ }
$h = (Get-Process -Id $ProcId).MainWindowHandle
if ($Focus) {
  $fg = [PMK]::GetForegroundWindow()
  $t1 = [PMK]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  $t2 = [PMK]::GetCurrentThreadId()
  [PMK]::AttachThreadInput($t2, $t1, $true) | Out-Null
  [PMK]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [PMK]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)  # Alt tap unlocks focus change
  [PMK]::SetForegroundWindow($h) | Out-Null
  [PMK]::AttachThreadInput($t2, $t1, $false) | Out-Null
  Start-Sleep -Milliseconds 300
}
# Make Unreal believe its window is active (it drops keyboard input otherwise).
[PMK]::PostMessage($h, 0x001C, [IntPtr]1, [IntPtr]0) | Out-Null   # WM_ACTIVATEAPP
[PMK]::PostMessage($h, 0x0006, [IntPtr]1, [IntPtr]0) | Out-Null   # WM_ACTIVATE (WA_ACTIVE)
[PMK]::PostMessage($h, 0x0007, [IntPtr]0, [IntPtr]0) | Out-Null   # WM_SETFOCUS
Start-Sleep -Milliseconds 150
if ($Vk) {
  $sc = [PMK]::MapVirtualKey($Vk, 0)
  [PMK]::PostMessage($h, 0x0100, [IntPtr]$Vk, [IntPtr](1 -bor ($sc -shl 16))) | Out-Null
  Start-Sleep -Milliseconds $HoldMs
  [PMK]::PostMessage($h, 0x0101, [IntPtr]$Vk, [IntPtr](1 -bor ($sc -shl 16) -bor (3 -shl 30))) | Out-Null
}
if ($Click) {
  $lp = [IntPtr](($Y -shl 16) -bor $X)
  if ($X -ne 640 -or $Y -ne 360) {
    $pt = New-Object PMK+PT; $pt.X = $X; $pt.Y = $Y
    [PMK]::ClientToScreen($h, [ref]$pt) | Out-Null
    [PMK]::SetCursorPos($pt.X, $pt.Y) | Out-Null
    [PMK]::PostMessage($h, 0x0200, [IntPtr]0, $lp) | Out-Null
    Start-Sleep -Milliseconds 200
  }
  [PMK]::PostMessage($h, 0x0201, [IntPtr]1, $lp) | Out-Null
  Start-Sleep -Milliseconds $HoldMs
  [PMK]::PostMessage($h, 0x0202, [IntPtr]0, $lp) | Out-Null
}
