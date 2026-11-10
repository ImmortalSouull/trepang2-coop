# Start game copy A and/or B windowed and wait until the T2Dev remote is ready.
# Usage: launch.ps1 -Which A,B [-Kill]
param([string[]]$Which = @("A"), [switch]$Kill)
$roots = @{
  A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64"
  B = "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64"
  C = "C:\Users\PC\Trepang2_C\CPPFPS\Binaries\Win64"
}
$pos = @{ A = @(0, 0); B = @(1300, 0); C = @(0, 740) }
if ($Kill) { Get-Process CPPFPS* -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 3 }
foreach ($i in $Which) {
  $w = $roots[$i]
  Remove-Item "$w\ue4ss\UE4SS.log" -ErrorAction SilentlyContinue
  Set-Content "$w\ue4ss\Mods\T2Dev\cmd.txt" "" -NoNewline
  Start-Process "$w\CPPFPS-Win64-Shipping.exe" -WorkingDirectory $w -ArgumentList "-windowed", "-ResX=1280", "-ResY=720", "-WinX=$($pos[$i][0])", "-WinY=$($pos[$i][1])"
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
