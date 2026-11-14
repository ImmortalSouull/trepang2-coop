# Send commands to a running Trepang2 instance and show new log lines.
# -Mod T2Dev (default): lines are console commands, or "lua:<code>" for Lua in the T2Dev mod.
# -Mod T2Coop: every line is Lua run inside the T2Coop mod (T2C table).
# Usage: t2.ps1 -Inst A|B -Cmd "..." [-Mod T2Coop] [-Wait 5] [-Grep pattern]
param([string]$Inst = "A", [string[]]$Cmd = @(), [string]$Mod = "T2Dev", [int]$Wait = 5, [string]$Grep = "")
$roots = @{
  A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64"
  B = "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64"
  C = "C:\Users\PC\Trepang2_C\CPPFPS\Binaries\Win64"
  D = "C:\Users\PC\Trepang2_D\CPPFPS\Binaries\Win64"
}
$w = $roots[$Inst]
$log = "$w\ue4ss\UE4SS.log"
$start = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
# (write a temp file and rename it in: the mod polls cmd.txt and could read a half-written long command)
if ($Cmd.Count) {
  $tmp = "$w\ue4ss\Mods\$Mod\cmd.tmp"
  [IO.File]::WriteAllText($tmp, ($Cmd -join "`n"))
  for ($k = 0; $k -lt 20; $k++) { try { Move-Item $tmp "$w\ue4ss\Mods\$Mod\cmd.txt" -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 50 } }
}
Start-Sleep $Wait
$new = Get-Content $log | Select-Object -Skip $start
if ($Grep) { $new = $new | Select-String -Pattern $Grep | ForEach-Object Line }
$new | Select-Object -Last 80
