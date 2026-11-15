# Late joins + a crashed partner coming back: host A on -Map, partners join one by one (-Gap s apart) while
# the others play; then D's game is killed, started again and joins again. Every copy reports who it sees.
# Campaign maps overwrite the campaign save: back it up first (see CLAUDE.md).
param([string]$Map = "/Game/Maps/Campaign/Cultists/KillCultists_Persistent", [int]$Gap = 30)
$D = $PSScriptRoot
$all = @("A", "B", "C", "D")
$roots = @{ A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2"; B = "C:\Users\PC\Trepang2_B"; C = "C:\Users\PC\Trepang2_C"; D = "C:\Users\PC\Trepang2_D" }
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$cb = @(Get-ChildItem $crashDir -Directory -EA 0 | ForEach-Object Name)
function Cmd($i, $lua, $wait = 1.2) { & "$D\t2.ps1" -Inst $i -Mod T2Coop -Cmd $lua -Wait $wait | Out-Null }
$see = 'pcall(T2C.stopLoadingScreen); local n=0; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:IsValid() and not p.bIsDead and not p.bHidden then n=n+1 end end; pcall(function() for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() and x.Pawn and x.Pawn:IsValid() and x.Pawn.bHidden then n=n+1 end end end); return "SEE "..n'
function Report($tag, $who) {
  $o = foreach ($i in $who) { $r = & "$D\t2.ps1" -Inst $i -Mod T2Coop -Cmd $see -Wait 2 -Grep "cmd ok"; "$i=" + ("$r" -replace '.*cmd ok: SEE ', '') }
  $rc = foreach ($i in $who | Where-Object { $_ -ne "A" }) { "$i" + ":" + @(Select-String "$($roots[$i])\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log" -Pattern "reconnecting" -EA 0).Count }
  $new = @(Get-ChildItem $crashDir -Directory -EA 0 | Where-Object { $cb -notcontains $_.Name })
  "$tag  see[$($o -join ' ')]  reconnects[$($rc -join ' ')]  procs=$(@(Get-Process CPPFPS-Win64-Shipping -EA 0).Count) crashes=$($new.Count)"
}
& "$D\deploy.ps1" | Out-Null
& "$D\launch.ps1" -Which $all -Kill | Out-Null
Start-Sleep 5
Cmd A "T2C.devGod=true; T2C.host('$Map'); return 'host'" 45
Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 3
$in = @("A")
foreach ($c in "B", "C", "D") {
  Cmd $c 'T2C.join("127.0.0.1"); return "join"' 2
  # the others keep playing meanwhile: walk around
  for ($k = 0; $k -lt [math]::Ceiling($Gap / 5); $k++) { foreach ($i in $in | Where-Object { $_ -ne "A" }) { Cmd $i 'T2C.walk(1); return "w"' 0 }; Start-Sleep 4 }
  $in += $c
  Report "after $c joined" $in
}
# D crashes: its game is killed, started again, joins again
Get-Process CPPFPS-Win64-Shipping | Where-Object { $_.Path -like "$($roots['D'])*" } | Stop-Process -Force
Start-Sleep 15
Report "D gone" @("A", "B", "C")
& "$D\launch.ps1" -Which D | Out-Null
Cmd D 'T2C.join("127.0.0.1"); return "join"' 40
Report "D back" $all
