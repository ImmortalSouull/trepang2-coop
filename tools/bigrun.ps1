# Big all-features run for 1..4 players (host A + partners B, C, D).
#   bigrun.ps1 -Players N [-Arenas K] [-Out file]
# Phases: solo game without co-op (1 player only), Horde (join, menus F4/F6, EXTRAS, looks, fight with
# partner damage, down/revive, spectating, wipe -> arena restart), K Horde arenas (partners follow),
# every campaign map (join, level restart, checkpoint reload), elevator ride + fall rescue
# (KillCultists), mission end -> safehouse (KillGhosts), the credits, every side mission.
# After every step: all games alive, no new crash dumps, no new Lua errors. One line per check in -Out.
# Campaign maps overwrite the campaign save: back it up first (see CLAUDE.md).
param([int]$Players = 2, [int]$Arenas = 10, [string]$Out = "", [switch]$SideOnly, [switch]$HordeOnly)
$T = $PSScriptRoot
$all = @("A", "B", "C", "D")[0..($Players - 1)]
$cl = @($all | Where-Object { $_ -ne "A" })
if (-not $Out) { $Out = "C:\Users\PC\trepang2-coop-work\bigrun_$Players.txt" }
$roots = @{ A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2"; B = "C:\Users\PC\Trepang2_B"; C = "C:\Users\PC\Trepang2_C"; D = "C:\Users\PC\Trepang2_D" }
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$crashBefore = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
$script:fails = 0; $script:checks = 0
$script:errSeen = @{}

function Res($l) { $line = "$(Get-Date -Format HH:mm:ss) $l"; for ($j = 0; $j -lt 5; $j++) { try { [IO.File]::AppendAllText($Out, $line + "`r`n"); break } catch { Start-Sleep -Milliseconds 200 } }; $line }
function Cmd($i, $lua, $wait = 1) { & "$T\t2.ps1" -Inst $i -Mod T2Coop -Cmd $lua -Wait $wait | Out-Null }
function Q($i, $lua, $wait = 2) { $r = & "$T\t2.ps1" -Inst $i -Mod T2Coop -Cmd $lua -Wait $wait -Grep "cmd (ok|error)"; ("$r" -replace '.*cmd (ok|error): ', '') }
function Check($name, $ok, $detail = "") {
  $script:checks++
  if (-not $ok) { $script:fails++ }
  Res ("{0} {1} {2}" -f $(if ($ok) { "OK  " } else { "FAIL" }), $name, $detail)
}
function LogLines($i) { $f = "$($roots[$i])\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log"; if (Test-Path $f) { Get-Content $f -ErrorAction SilentlyContinue } else { @() } }
# new Lua errors of the mod (not the errors of our own test commands)
function NewErrors {
  $o = @()
  foreach ($i in $all) {
    $lines = @(LogLines $i | Where-Object { ($_ -match "\[T2Coop\]|\[Lua\]") -and ($_ -match "(?i)error|traceback") -and ($_ -notmatch "cmd error") })
    $k = "$i"; $seen = $script:errSeen[$k]; if (-not $seen) { $seen = 0 }
    if ($lines.Count -lt $seen) { $seen = 0 }   # log restarted
    if ($lines.Count -gt $seen) { $o += $lines[$seen..($lines.Count - 1)] | ForEach-Object { "$i $_" } }
    $script:errSeen[$k] = $lines.Count
  }
  $o
}
function Health($step) {
  $procs = @(Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue)
  $hung = @($procs | Where-Object { -not $_.Responding }).Count
  $new = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | Where-Object { $crashBefore -notcontains $_.Name })
  foreach ($c in $new) {
    $x = Get-Content (Join-Path $c.FullName "CrashContext.runtime-xml") -Raw -ErrorAction SilentlyContinue
    Res ("CRASH {0} {1} {2}" -f $c.Name, [regex]::Match("$x", '<BaseDir>(.*?)</BaseDir>').Groups[1].Value, [regex]::Match("$x", '<ErrorMessage>(.*?)</ErrorMessage>').Groups[1].Value) | Out-Host
    $script:crashBefore += $c.Name
  }
  $errs = @(NewErrors)
  foreach ($e in ($errs | Select-Object -First 6)) { Res "LUAERR $e" | Out-Host }
  Check "$step / games alive" ($procs.Count -eq $Players -and $hung -eq 0 -and $new.Count -eq 0 -and $errs.Count -eq 0) "procs=$($procs.Count) hung=$hung crashes=$($new.Count) luaErrors=$($errs.Count)" | Out-Host
  return ($procs.Count -eq $Players -and $hung -eq 0)
}
$seeLua = 'pcall(T2C.stopLoadingScreen); local n=0; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:IsValid() and not p.bIsDead and not p.bHidden then n=n+1 end end; pcall(function() for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() and x.Pawn and x.Pawn:IsValid() and x.Pawn.bHidden then n=n+1 end end end); local GS=StaticFindObject("/Script/Engine.Default__GameplayStatics"); return "SEE "..n.." "..GS:GetCurrentLevelName(FindFirstOf("PlayerController"):GetWorld(), true):ToString()'
# every copy sees every player (retries while partners are still coming in)
function SeeAll($step, $tries = 8) {
  $txt = ""
  for ($k = 0; $k -lt $tries; $k++) {
    $ok = $true; $txt = ""
    foreach ($i in $all) {
      $r = Q $i $seeLua 2
      $txt += " $i[$r]"
      if ($r -notmatch "^SEE $Players ") { $ok = $false }
    }
    if ($ok) { break }
    Start-Sleep 8
  }
  Check "$step / everyone sees $Players" $ok $txt
}
function Setup($map) {
  & "$T\launch.ps1" -Which $all -Kill | Out-Null
  Start-Sleep 5
  Cmd A "T2C.devGod=true; T2C.host('$map'); return 'host'" 42
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
  foreach ($c in $cl) { Cmd $c 'T2C.join("127.0.0.1"); return "join"' 2 }
  if ($cl.Count) { Start-Sleep 25 }
  foreach ($i in $all) { [void](Q $i 'return "x"' 1) }
  [void](NewErrors)
}
function Recover($map, $why) { Res "RECOVER ($why): restarting all games on $map"; Setup $map }
function God { foreach ($c in $cl) { Cmd $c 'pcall(function() local p=T2C.client.pawn; p:SetInvulnerableState(true); if p.Health<150 then p.Health=200 end end); return "g"' 0 } }
function HostTravel($map, $wait = 40) {
  Cmd A "T2C.host('$map'); return 'host'" $wait
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
}

Res "===== BIG RUN: $Players player(s) - $($all -join ',') - v$((Select-String "$T\..\mod\T2Coop\Scripts\main.lua" -Pattern 'local VERSION = "([^"]+)"').Matches[0].Groups[1].Value)"
& "$T\deploy.ps1" | Out-Null

if (-not $SideOnly) {
# ---------------------------------------------------------------- solo (the game with the mod, no co-op)
if ($Players -eq 1) {
  & "$T\launch.ps1" -Which A -Kill | Out-Null; Start-Sleep 5
  [void](NewErrors)
  foreach ($m in @("/Game/Maps/Campaign/Cultists/KillCultists_Persistent", "/Game/Maps/HordeMode/Horde_Killhouse")) {
    Cmd A "local K=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary'); local pc=FindFirstOf('PlayerController'); K:ExecuteConsoleCommand(pc:GetWorld(),'open $m',pc); return 'open'" 45
    Cmd A 'pcall(T2C.stopLoadingScreen); return "k"' 6
    $r = Q A 'pcall(T2C.stopLoadingScreen); local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; return "solo pawn="..tostring(p and p:IsValid()).." hosting="..tostring(T2C.hosting).." joined="..tostring(T2C.joined)' 3
    Check "solo $(($m -split '/')[-1]) - plain game, mod idle" ($r -match "pawn=true hosting=(false|nil) joined=(false|nil)") $r
    $r = Q A 'T2C.menuTab("coop"); T2C.menuOpen(); local a=T2C.playerList(); T2C.menuTab("look"); T2C.menuTab("extras"); T2C.menuClose(); local q=#T2C.quickList(); T2C.menuF6(); T2C.menuClose(); return "menus players="..#a.." quick="..q' 4
    Check "solo F4 tabs + F6" ($r -match "menus players=1 quick=\d+") $r
    $r = Q A 'T2C.walk(2); return T2C.shootNearest(6)' 6
    Check "solo walk + shoot" ($r -match "aiming at|no enemy") $r
    [void](Health "solo $(($m -split '/')[-1])")
  }
}

# ---------------------------------------------------------------- Horde
$horde = "/Game/Maps/HordeMode/Horde_Killhouse"
Setup $horde
SeeAll "horde join"
if (-not (Health "horde join")) { Recover $horde "join"; SeeAll "horde join (again)" }

# F4 (all three tabs) and F6 on every copy; the player list shows everyone
foreach ($i in $all) {
  for ($try = 0; $try -lt 3; $try++) {
    $r = Q $i 'T2C.menuTab("coop"); T2C.menuOpen(); local a=T2C.playerList(); T2C.menuTab("look"); T2C.menuTab("extras"); T2C.menuClose(); local q=#T2C.quickList(); T2C.menuF6(); T2C.menuClose(); return "menus players="..#a.." quick="..q' 5
    if ($r -match "menus players=$Players ") { break }; Start-Sleep 5   # (a newcomer's name arrives a moment later)
  }
  Check "F4/F6 menus on $i" ($r -match "menus players=$Players quick=\d+") $r
}
[void](Health "menus")

# EXTRAS: every option at its strongest on every copy for a while, then back to off
$xOn = 'for _,e in ipairs(T2C.extrasSpec) do T2C.extras[e.key]=e.vals[#e.vals] end; T2C.saveExtras(); return "x on"'
$xOff = 'for _,e in ipairs(T2C.extrasSpec) do T2C.extras[e.key]=e.vals[1] end; T2C.saveExtras(); return "x off"'
foreach ($i in $all) { Cmd $i $xOn 0 }
Start-Sleep 35
foreach ($i in $all) {
  $r = Q $i 'local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; return string.format("armor max %s regen %s", tostring(p.MaxArmor), tostring(T2C.extras.regen))' 2
  Check "EXTRAS on $i" ($r -match "regen 100") $r
}
foreach ($i in $all) {
  for ($k = 0; $k -lt 3; $k++) { $r = Q $i ($xOff -replace 'return "x off"', 'return "x off regen="..tostring(T2C.extras.regen)') 2; if ($r -match "regen=0") { break } }
  Check "EXTRAS back off on $i" ($r -match "regen=0") $r | Out-Host
}
[void](Health "extras")

# looks: everyone wears a different enemy look, F4 LOOK preview open for a moment
$n = 0
foreach ($i in $all) {
  $n++
  $r = Q $i "local all={}; for _,g in ipairs(T2C.catalog()) do for _,e in ipairs(g.list) do table.insert(all,e.id) end end; local id=all[(os.time()*7+$n*37) % #all + 1]; T2C.mySkin=id; T2C.menuTab('look'); T2C.menuOpen(); return 'look '..tostring(id)" 3
  Check "look on $i" ($r -match "^look ") $r
}
Start-Sleep 6
foreach ($i in $all) { Cmd $i 'T2C.menuClose(); T2C.mySkin=nil; return "c"' 0 }
[void](Health "looks")

# fight: partners shoot first (their damage must reach the host's enemies), then everyone
God
$deadLua = 'local d,a,h=0,0,0; for _,c in ipairs(T2C.allOf("/Script/CPPFPS.BaseCharacter")) do if not c:IsA(StaticFindObject("/Script/CPPFPS.BasePlayer")) then if c.bIsDead then d=d+1 else a=a+1; h=h+(tonumber(c.Health) or 0) end end end; return string.format("dead %d alive %d hp %.0f", d, a, h)'
$before = Q A $deadLua 2
for ($k = 0; $k -lt 12; $k++) {
  foreach ($c in $cl) {
    Cmd $c 'local e; for _,c in ipairs(T2C.allOf("/Script/CPPFPS.BaseCharacter")) do if not c:IsA(StaticFindObject("/Script/CPPFPS.BasePlayer")) and not c.bIsDead then e=c end end; if not e then return "none" end; local l=e:K2_GetActorLocation(); local p=T2C.client.pawn; p:K2_SetActorLocation({X=l.X-250,Y=l.Y,Z=l.Z+30}, false, {}, true); local pc; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then pc=x end end; local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); pc:SetControlRotation(KML:FindLookAtRotation(pc.PlayerCameraManager:GetCameraLocation(), l)); return "aim"' 1
    $pid2 = (Get-Process CPPFPS-Win64-Shipping | Where-Object { $_.Path -like "$($roots[$c])*" }).Id
    if ($pid2) { & "$T\key.ps1" -ProcId $pid2 -Focus -Click -HoldMs 1200 | Out-Null }
  }
  if ($cl.Count -eq 0) { Cmd A 'local e; for _,c in ipairs(T2C.allOf("/Script/CPPFPS.BaseCharacter")) do if not c:IsA(StaticFindObject("/Script/CPPFPS.BasePlayer")) and not c.bIsDead then e=c end end; if e then local l=e:K2_GetActorLocation(); local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; p:K2_SetActorLocation({X=l.X-250,Y=l.Y,Z=l.Z+30}, false, {}, true) end; return T2C.shootNearest(8)' 0 }
  Start-Sleep 4
  God
}
$after = Q A $deadLua 2
$h0 = if ($before -match "alive (\d+) hp (\d+)") { @([int]$Matches[1], [int]$Matches[2]) } else { @(0, 0) }
$h1 = if ($after -match "alive (\d+) hp (\d+)") { @([int]$Matches[1], [int]$Matches[2]) } else { @(0, 0) }
# (corpses vanish and new enemies come: damage = less health among the living, or fewer living)
$hit = ($h1[0] -lt $h0[0]) -or ($h1[0] -eq $h0[0] -and $h1[1] -lt $h0[1])
Check "$(if ($cl.Count) {'partner'} else {'host'}) damage/kills reach the host" $hit "$before -> $after"
for ($k = 0; $k -lt 8; $k++) { foreach ($i in $all) { Cmd $i 'T2C.walk(1); return T2C.shootNearest(6)' 0 }; Start-Sleep 3; God }
[void](Health "fight")
SeeAll "after the fight"

if ($cl.Count -ge 1) {
  # down + revive next to a partner
  $b = $cl[0]
  Cmd A 'local hp; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then hp=x.Pawn end end; local l=hp:K2_GetActorLocation(); for _,pc in ipairs(FindAllOf("PlayerController")) do if not pc:IsLocalController() and pc.Pawn and pc.Pawn:IsValid() then end end; return "x"' 0
  $hostLoc = Q A 'local hp; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then hp=x.Pawn end end; local l=hp:K2_GetActorLocation(); return string.format("%.0f|%.0f|%.0f", l.X, l.Y, l.Z)' 1
  $xyz = $hostLoc -split "\|"
  Cmd $b "local p=T2C.client.pawn; p:SetInvulnerableState(false); p:K2_SetActorLocation({X=$($xyz[0])+120,Y=$($xyz[1]),Z=$($xyz[2])+30}, false, {}, true); T2C.walk(0.3); return 'near'" 3
  Cmd $b "T2C.client.pawn.Health=10; return 'hurt'" 9
  $r = Q $b 'return "down="..tostring(T2C.me and T2C.me.down)' 1
  $log = (LogLines $b | Select-Object -Last 60) -join "`n"
  Check "down + revive next to the host ($b)" (($log -match "you are DOWN") -and ($log -match "revived")) $r
  God
  # spectating: everyone else far away, $b goes down, watches a partner, left click cycles
  Cmd $b "local p=T2C.client.pawn; p:SetInvulnerableState(false); p:K2_SetActorLocation(T2C.freeSpotNear(p, 10), false, {}, true); T2C.walk(0.3); return 'far'" 3
  Cmd $b "T2C.client.pawn.Health=10; return 'hurt'" 5
  $r = Q $b 'local pc; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then pc=x end end; local v=pc:GetViewTarget(); return "view "..v:GetFName():ToString().." own "..T2C.client.pawn:GetFName():ToString().." idx "..tostring(T2C.spec.idx)' 1
  Check "spectating a partner while down ($b)" ($r -match "^view (\S+) own (\S+)" -and $Matches[1] -ne $Matches[2]) $r
  if ($Players -ge 3) {
    $pb = (Get-Process CPPFPS-Win64-Shipping | Where-Object { $_.Path -like "$($roots[$b])*" }).Id
    & "$T\key.ps1" -ProcId $pb -Click -HoldMs 120 | Out-Null; Start-Sleep 2
    $r2 = Q $b 'local pc; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then pc=x end end; return "view "..pc:GetViewTarget():GetFName():ToString().." idx "..tostring(T2C.spec.idx)' 1
    Check "left click switches to the next partner ($b)" ($r2 -match "idx 2") "$r -> $r2"
  }
  # the host comes over: revived
  # (to the downed partner's body on the HOST - the server's copy of it)
  Cmd A "local hp; for _,x in ipairs(FindAllOf('PlayerController')) do if x:IsLocalController() then hp=x.Pawn end end; for _,pc in ipairs(FindAllOf('PlayerController')) do local d=T2C.downed[pc:GetFName():ToString()]; if d and d.down and pc.Pawn:IsValid() then local l=pc.Pawn:K2_GetActorLocation(); hp:K2_SetActorLocation({X=l.X-100,Y=l.Y,Z=l.Z+20}, false, {}, true) end end; return 'go'" 12
  $r = Q $b 'local pc; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then pc=x end end; return "down="..tostring(T2C.me and T2C.me.down).." view "..pc:GetViewTarget():GetFName():ToString().." own "..T2C.client.pawn:GetFName():ToString()' 1
  $log = (LogLines $b | Select-Object -Last 40) -join "`n"
  Check "revived by the host, own view back ($b)" (($log -match "revived") -and ($r -match "view (\S+) own (\S+)") -and $Matches[1] -eq $Matches[2]) $r
  God
  [void](Health "down/revive/spectate")

  # everyone down, far apart: the arena restarts and everybody comes back
  $k = 0
  foreach ($c in $cl) { $k++; Cmd $c "local p=T2C.client.pawn; p:SetInvulnerableState(false); p:K2_SetActorLocation({X=$($xyz[0])+1500*$k,Y=$($xyz[1])+600,Z=$($xyz[2])+60}, false, {}, true); p.Health=10; return 'down'" 0 }
  Cmd A 'T2C.devGod=false; local hp; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then hp=x.Pawn end end; hp:SetInvulnerableState(false); hp.Health=10; return "down"' 45
  Cmd A 'T2C.devGod=true; pcall(T2C.stopLoadingScreen); return "ok"' 25
  $log = (LogLines A | Select-Object -Last 200) -join "`n"
  Check "everyone down -> arena restarts" ($log -match "everyone is down - restarting the arena") ""
  SeeAll "after the wipe"
  if (-not (Health "wipe")) { Recover $horde "wipe" }
}

# ---------------------------------------------------------------- Horde arenas
$arenaList = @(Get-Content "C:\Users\PC\trepang2-coop-work\hordemaps.txt" -ErrorAction SilentlyContinue)
if ($arenaList.Count -eq 0) { $arenaList = @("/Game/Maps/HordeMode/Horde_Killhouse") }
$pick = if ($Arenas -gt 0) { $arenaList | Get-Random -Count ([math]::Min($Arenas, $arenaList.Count)) } else { @() }
foreach ($m in $pick) {
  HostTravel $m 40
  Start-Sleep 15
  SeeAll "arena $(($m -split '/')[-1])"
  if (-not (Health "arena $(($m -split '/')[-1])")) { Recover $m "arena" }
}

if (-not $HordeOnly) {
# ---------------------------------------------------------------- campaign
$camp = @("/Game/Maps/Campaign/Prologue/Prologue_Persistent", "/Game/Maps/Campaign/Cultists/KillCultists_Persistent",
  "/Game/Maps/Campaign/Ghosts/KillGhosts_Persistent", "/Game/Maps/Campaign/SafeHouse/KillSyndicate_Persistent",
  "/Game/Maps/Campaign/Horizon/KillHorizon_Persistent", "/Game/Maps/Campaign/Mothman/Version_01/KillMothman_Persistent",
  "/Game/Maps/Campaign/SafeHouse/SafeHouse_Persistent")
foreach ($m in $camp) {
  $s = ($m -split "/")[-1]
  HostTravel $m 45
  Start-Sleep 15
  SeeAll "$s join"
  if (-not (Health "$s join")) { Recover $m $s; continue }
  Cmd A 'local L=StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C"); local w=FindFirstOf("PlayerController"):GetWorld(); L["Trepang Restart Level"](L, w, w); return "travel"' 40
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 20
  SeeAll "$s restart"
  if (-not (Health "$s restart")) { Recover $m $s; continue }
  Cmd A 'T2C.loadLastSave(); return "load"' 40
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 20
  SeeAll "$s checkpoint reload"
  if (-not (Health "$s checkpoint")) { Recover $m $s; continue }
  if ($s -eq "KillCultists_Persistent" -and $cl.Count) {
    # the hub elevator with everyone on it
    Cmd A 'local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; p:K2_SetActorLocation({X=-6640,Y=10050,Z=760}, false, {}, true); return "on"' 0
    $k = 0
    foreach ($c in $cl) { $k++; Cmd $c "T2C.client.pawn:K2_SetActorLocation({X=-6640+80*$k,Y=9800,Z=760}, false, {}, true); return 'on'" 0 }
    Start-Sleep 2
    Cmd A 'FindFirstOf("BP_CultistHubElevator_C"):TravelDown(); return "down"' 25
    foreach ($c in $cl) {
      $r = Q $c 'local l=T2C.client.pawn:K2_GetActorLocation(); return string.format("z %.0f", l.Z)' 1
      Check "elevator took $c down" ($r -match "z (-?\d+)" -and [int]$Matches[1] -lt 600) $r
    }
    # fall off the map: back to the host
    $f = $cl[-1]
    Cmd $f 'local w=FindFirstOf("WorldSettings"); local p=T2C.client.pawn; local l=p:K2_GetActorLocation(); w.KillZ=l.Z-5000; T2C.killZLevel=nil; p:K2_SetActorLocation({X=l.X+2500,Y=l.Y,Z=l.Z-1200}, false, {}, true); return "drop"' 12
    $log = (LogLines $f | Select-Object -Last 60) -join "`n"
    Check "fall rescue ($f)" ($log -match "(?i)fell|выпал") ""
    [void](Health "elevator + fall")
  }
}

# mission end -> safehouse
HostTravel "/Game/Maps/Campaign/Ghosts/KillGhosts_Persistent" 45
Start-Sleep 10
Cmd A 'local w=FindFirstOf("PlayerController"):GetWorld(); for i=1,#w.StreamingLevels do local s=w.StreamingLevels[i]; pcall(function() s:SetShouldBeLoaded(true) end) end; return "all"' 12
Cmd A 'local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; for _,t in ipairs(FindAllOf("Trigger_EndLevel_C") or {}) do t.TriggerDisabled=false; t:TryTrigger(p, {}); return "fired" end; return "none"' 45
Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 25
SeeAll "KillGhosts end -> safehouse" 10
$r = Q A $seeLua 2
Check "mission end lands in the safehouse" ($r -match "SafeHouse") $r
if (-not (Health "mission end")) { Recover "/Game/Maps/Campaign/Credits/Credits_Persistent" "end" }

# credits
HostTravel "/Game/Maps/Campaign/Credits/Credits_Persistent" 45
Start-Sleep 10
foreach ($i in $all) { $r = Q $i 'local GS=StaticFindObject("/Script/Engine.Default__GameplayStatics"); return GS:GetCurrentLevelName(FindFirstOf("PlayerController"):GetWorld(), true):ToString()' 2; Check "credits on $i" ($r -match "Credits") $r }
[void](Health "credits")

}   # (not -HordeOnly)
}   # (not -SideOnly)
if ($SideOnly) { Setup "/Game/Maps/HordeMode/Horde_Killhouse" }
if (-not $HordeOnly) {
# ---------------------------------------------------------------- side missions
$side = @("BadOil/SideMission_BadOil", "Cavern/SideMission_Cavern", "GroundedAviation/SideMission_GroundedAviation", "OilRig/SideMission_OilRig",
  "ServerRoom/SideMission_ServerRoom", "TeamSpirit/SideMission_TeamSpirit", "WetBasement/SideMission_WetBasement")
$firstSide = $true
foreach ($m in $side) {
  HostTravel "/Game/Maps/SideMissions/$m" 45
  # after the credits partners end co-op on purpose ("the end"): join again for the side missions
  if ($firstSide) { foreach ($c in $cl) { Cmd $c 'T2C.join("127.0.0.1"); return "join"' 2 }; Start-Sleep 20; $firstSide = $false }
  Start-Sleep 15
  SeeAll "side $m"
  if (-not (Health "side $m")) { Recover "/Game/Maps/SideMissions/$m" "side" }
}

}   # (side: not -HordeOnly)
Res "===== DONE: $Players player(s): $($script:checks - $script:fails)/$($script:checks) checks OK, $($script:fails) failed"
