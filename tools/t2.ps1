# Send commands to a running Trepang2 instance and show new log lines.
# -Mod T2Dev (default): lines are console commands, or "lua:<code>" for Lua in the T2Dev mod.
# -Mod T2Coop: every line is Lua run inside the T2Coop mod (T2C table).
# Usage: t2.ps1 -Inst A|B -Cmd "..." [-Mod T2Coop] [-Wait 5] [-Grep pattern]
param([string]$Inst = "A", [string[]]$Cmd = @(), [string]$Mod = "T2Dev", [int]$Wait = 5, [string]$Grep = "")
$roots = @{
  A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64"
  B = "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64"
}
$w = $roots[$Inst]
$log = "$w\ue4ss\UE4SS.log"
$start = if (Test-Path $log) { (Get-Content $log).Count } else { 0 }
if ($Cmd.Count) { [IO.File]::WriteAllText("$w\ue4ss\Mods\$Mod\cmd.txt", ($Cmd -join "`n")) }
Start-Sleep $Wait
$new = Get-Content $log | Select-Object -Skip $start
if ($Grep) { $new = $new | Select-String -Pattern $Grep | ForEach-Object Line }
$new | Select-Object -Last 80
