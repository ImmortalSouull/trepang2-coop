# Start game copy A and/or B windowed and wait until the T2Dev remote is ready.
# Usage: launch.ps1 -Which A,B [-Kill]
# -Grid: 960x540 windows in a 2x2 grid that fits the screen (4-player showcase recording)
param([string[]]$Which = @("A"), [switch]$Kill, [switch]$Grid)
$roots = @{
  A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64"
  B = "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64"
  C = "C:\Users\PC\Trepang2_C\CPPFPS\Binaries\Win64"
  D = "C:\Users\PC\Trepang2_D\CPPFPS\Binaries\Win64"
}
$pos = @{ A = @(0, 0); B = @(1290, 0); C = @(0, 740); D = @(1290, 740) }
$res = @(1280, 720)
if ($Grid) { $pos = @{ A = @(0, 0); B = @(1000, 0); C = @(0, 600); D = @(1000, 600) }; $res = @(960, 540) }
if ($Kill) { Get-Process CPPFPS* -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 3 }
foreach ($i in $Which) {
  $w = $roots[$i]
  # keep the last session's log (a crash before a restart is otherwise lost)
  if (Test-Path "$w\ue4ss\UE4SS.log") { Move-Item "$w\ue4ss\UE4SS.log" "$w\ue4ss\UE4SS.prev.log" -Force -ErrorAction SilentlyContinue }
  Remove-Item "$w\ue4ss\UE4SS.log" -ErrorAction SilentlyContinue
  Set-Content "$w\ue4ss\Mods\T2Dev\cmd.txt" "" -NoNewline
  $a = @("-windowed", "-ResX=$($res[0])", "-ResY=$($res[1])", "-WinX=$($pos[$i][0])", "-WinY=$($pos[$i][1])")
  Start-Process "$w\CPPFPS-Win64-Shipping.exe" -WorkingDirectory $w -ArgumentList $a
}
foreach ($i in $Which) {
  $log = "$($roots[$i])\ue4ss\UE4SS.log"
  for ($t = 0; $t -lt 120; $t += 2) {
    Start-Sleep 2
    if ((Test-Path $log) -and (Select-String $log -Pattern '\[T2Dev\] ready' -Quiet)) { break }
  }
  "$i ready after ~$t s"
}
Start-Sleep 20  # let the front-end map finish loading
