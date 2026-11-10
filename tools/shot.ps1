# Capture a game window even when covered (PrintWindow). Usage: shot.ps1 -ProcId <pid> -Out <png>
param([int]$ProcId, [string]$Out)
Add-Type -AssemblyName System.Drawing
if (-not ("PW" -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices;
public class PW {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
}
"@ }
$p = Get-Process -Id $ProcId
$h = $p.MainWindowHandle
$r = New-Object PW+R; [PW]::GetClientRect($h, [ref]$r) | Out-Null
$bmp = New-Object Drawing.Bitmap ([math]::Max(1,$r.Rr)), ([math]::Max(1,$r.B))
$g = [Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc(); [PW]::PrintWindow($h, $hdc, 3) | Out-Null; $g.ReleaseHdc($hdc)
$bmp.Save($Out); $Out
