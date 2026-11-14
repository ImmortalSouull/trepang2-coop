# N rounds: everyone (host + partners) goes down far apart while partners spectate -> the arena restarts
# and everybody comes back. Crash check; a crashed copy's UE4SS.log is kept as C:\Users\PC\trepang2-coop-work\wipe_<n>_<copy>.log
param([int]$Count = 5, [int]$Players = 4)
$T = $PSScriptRoot
$all = @("A", "B", "C", "D")[0..($Players - 1)]
$cl = @($all | Where-Object { $_ -ne "A" })
$roots = @{ A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2"; B = "C:\Users\PC\Trepang2_B"; C = "C:\Users\PC\Trepang2_C"; D = "C:\Users\PC\Trepang2_D" }
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$cb = @(Get-ChildItem $crashDir -Directory -EA 0 | ForEach-Object Name)
function Cmd($i, $lua, $wait = 1) { & "$T\t2.ps1" -Inst $i -Mod T2Coop -Cmd $lua -Wait $wait | Out-Null }
$env:T2RX = "1"
& "$T\test_four.ps1" -Clients $cl 2>&1 | Select-Object -Last 1
for ($n = 1; $n -le $Count; $n++) {
  $k = 0
  foreach ($c in $cl) {
    $k++
    Cmd $c "local p=T2C.client.pawn; local l=p:K2_GetActorLocation(); p:SetInvulnerableState(false); p:K2_SetActorLocation({X=l.X+900*$k,Y=l.Y+500,Z=l.Z+60}, false, {}, true); T2C.walk(0.3); return 'far'" 0
  }
  Start-Sleep 3
  foreach ($c in $cl) { Cmd $c "T2C.client.pawn.Health=10; return 'down'" 0 }
  Start-Sleep 6
  Cmd A 'T2C.devGod=false; local hp; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then hp=x.Pawn end end; hp:SetInvulnerableState(false); hp.Health=10; return "down"' 50
  Cmd A 'T2C.devGod=true; pcall(T2C.stopLoadingScreen); return "ok"' 25
  $see = foreach ($i in $all) { $r = & "$T\t2.ps1" -Inst $i -Mod T2Coop -Cmd 'pcall(T2C.stopLoadingScreen); local n=0; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if not p.bHidden and not p.bIsDead then n=n+1 end end; return "SEE "..n' -Wait 2 -Grep "cmd ok"; "$i=" + ("$r" -replace '.*cmd ok: SEE ', '') }
  $new = @(Get-ChildItem $crashDir -Directory -EA 0 | Where-Object { $cb -notcontains $_.Name })
  "round $n procs=$(@(Get-Process CPPFPS-Win64-Shipping -EA 0).Count) crashes=$($new.Count) $($see -join ' ')"
  if ($new.Count -gt 0 -or @(Get-Process CPPFPS-Win64-Shipping -EA 0).Count -lt $Players) {
    foreach ($i in $all) { Copy-Item "$($roots[$i])\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log" "C:\Users\PC\trepang2-coop-work\wipe_${n}_$i.log" -EA 0 }
    foreach ($c in $new) { "  " + $c.FullName }
    break
  }
}
