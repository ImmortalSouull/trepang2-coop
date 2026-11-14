# Showcase takes for the final v1.0.0 with FOUR players: host A + partners B, C, D in a 2x2 grid
# (960x540 windows, launch.ps1 -Grid), recorded from the desktop in one capture.
#   horde     - Horde_Killhouse: three partners join one by one, F4 player list, a fight, down + revive,
#               spectating, everyone down -> the arena restarts
#   campaign  - KillCultists: everyone joins the mission, elevator ride with four, level restart
#   ghostsend - KillGhosts: the mission ends, all four arrive in the safehouse
# Writes raw.mkv, events.txt and rects.txt (client area of each window) into
# C:\Users\PC\trepang2-coop-work\caps\<Take>-<Part>.
# Campaign takes overwrite the campaign save: back it up first (see CLAUDE.md).
param([string]$Take = "v100q", [ValidateSet("horde", "campaign", "ghostsend")][string]$Part = "horde", [int]$Seconds = 200)
$D = $PSScriptRoot
$out = "C:\Users\PC\trepang2-coop-work\caps\$Take-$Part"
New-Item -ItemType Directory -Force $out | Out-Null
$ff = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName
$roots = @{ A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2"; B = "C:\Users\PC\Trepang2_B"; C = "C:\Users\PC\Trepang2_C"; D = "C:\Users\PC\Trepang2_D" }
$cl = @("B", "C", "D")
if (-not ("WS4" -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WS4 { [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
 [StructLayout(LayoutKind.Sequential)] public struct P { public int X,Y; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }
"@
}
$claude = Get-Process Claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$saved = $null
if ($claude) {
  $saved = New-Object WS4+R; [WS4]::GetWindowRect($claude.MainWindowHandle, [ref]$saved) | Out-Null
  [WS4]::SetWindowPos($claude.MainWindowHandle, [IntPtr](-1), 2400, 0, 1040, 1400, 0x40) | Out-Null
}
function PutClaudeBack {
  if ($claude -and $saved) {
    [WS4]::SetWindowPos($claude.MainWindowHandle, [IntPtr](-1), $saved.L, $saved.T, $saved.Rr - $saved.L, $saved.B - $saved.T, 0x40) | Out-Null
  }
}
# (at least 1.2 s: the mod reads its command file twice a second - a quicker next command overwrote it)
function Cmd($inst, $lua, $wait = 1) { & "$D\t2.ps1" -Inst $inst -Mod T2Coop -Cmd $lua -Wait ([math]::Max(1.2, $wait)) | Out-Null }
function Q($i, $lua, $wait = 2) { $r = & "$D\t2.ps1" -Inst $i -Mod T2Coop -Cmd $lua -Wait $wait -Grep "cmd (ok|error)"; ("$r" -replace '.*cmd (ok|error): ', '') }
function GamePid($i) { (Get-Process CPPFPS-Win64-Shipping | Where-Object { $_.Path -like "$($roots[$i])*" }).Id }
function WaitIn($c, $max = 20) {
  for ($i = 0; $i -lt $max; $i++) {
    $r = Q $c 'pcall(T2C.stopLoadingScreen); return "W "..T2C.where()' 3
    if ("$r" -match "PlayerBP_C") { return }
  }
}
# every copy looks at the middle of the other players
$face = 'local me; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then me=x end end; local sx,sy,sz,n=0,0,0,0; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:GetFullName()~=me.Pawn:GetFullName() and not p.bHidden and not p.bIsDead then local l=p:K2_GetActorLocation(); sx,sy,sz,n=sx+l.X,sy+l.Y,sz+l.Z,n+1 end end; if n==0 then return "none" end; local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); me:SetControlRotation(KML:FindLookAtRotation(me.PlayerCameraManager:GetCameraLocation(), {X=sx/n,Y=sy/n,Z=sz/n+40})); return "face"'
function FaceAll { foreach ($i in @("A") + $cl) { Cmd $i $face 0 } }
$hostPawn = 'local hp; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then hp=x.Pawn end end;'
# partners in an arc in front of the host
function Gather($dist = 320) {
  $h = Q A ($hostPawn + ' local l=hp:K2_GetActorLocation(); local f=hp:GetActorForwardVector(); return string.format("%.0f|%.0f|%.0f|%.3f|%.3f", l.X, l.Y, l.Z, f.X, f.Y)') 1
  $v = $h -split "\|"
  if ($v.Count -lt 5) { return }
  $x, $y, $z, $fx, $fy = [double]$v[0], [double]$v[1], [double]$v[2], [double]$v[3], [double]$v[4]
  $k = 0
  foreach ($c in $cl) {
    $a = (-0.6 + 0.6 * $k) ; $k++
    $dx = $fx * [math]::Cos($a) - $fy * [math]::Sin($a); $dy = $fx * [math]::Sin($a) + $fy * [math]::Cos($a)
    $px = [math]::Round($x + $dist * $dx); $py = [math]::Round($y + $dist * $dy); $pz = [math]::Round($z + 30)
    Cmd $c "T2C.client.pawn:K2_SetActorLocation({X=($px),Y=($py),Z=($pz)}, false, {}, true); return 'at'" 0
  }
  Start-Sleep 1
  FaceAll
}
function God {
  foreach ($c in $cl) { Cmd $c 'pcall(function() local p=T2C.client.pawn; p:SetInvulnerableState(true); if p.Health<150 then p.Health=200 end end); return "g"' 0 }
}
$map = @{ horde = "/Game/Maps/HordeMode/Horde_Killhouse"; campaign = "/Game/Maps/Campaign/Cultists/KillCultists_Persistent"; ghostsend = "/Game/Maps/Campaign/Ghosts/KillGhosts_Persistent" }[$Part]

& "$D\deploy.ps1" | Out-Null
try {
& "$D\launch.ps1" -Which A,B,C,D -Kill -Grid | Out-Null
Start-Sleep 5
# client area of every window -> rects.txt (the editor crops the tiles from the one capture)
$rects = foreach ($i in @("A") + $cl) {
  $h = (Get-Process -Id (GamePid $i)).MainWindowHandle
  $r = New-Object WS4+R; [WS4]::GetClientRect($h, [ref]$r) | Out-Null
  $p = New-Object WS4+P; [WS4]::ClientToScreen($h, [ref]$p) | Out-Null
  "$i $($p.X) $($p.Y) $($r.Rr) $($r.B)"
}
$rects | Set-Content "$out\rects.txt"
$rects
Cmd A "T2C.devGod=true; T2C.host('$map'); return 'host'" 42
Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
if ($Part -eq "ghostsend") {
  foreach ($c in $cl) { Cmd $c 'T2C.join("127.0.0.1"); return "join"' 2 }
  foreach ($c in $cl) { WaitIn $c }
  Start-Sleep 5
  Gather; God
}

$xOn = 'for _,e in ipairs(T2C.extrasSpec) do if e.key=="resupply" or e.key=="killsupply" or e.key=="regen" then T2C.extras[e.key]=e.vals[#e.vals] end end; T2C.saveExtras(); return "x on"'
foreach ($i in @("A") + $cl) { Cmd $i $xOn 1 }
$rec = Start-Process $ff -ArgumentList "-y -f gdigrab -framerate 30 -offset_x 0 -offset_y 0 -video_size 1992x1192 -draw_mouse 0 -i desktop -t $Seconds -c:v libx264 -preset ultrafast -crf 20 -g 15 `"$out\raw.mkv`"" -PassThru -WindowStyle Hidden
$t0 = Get-Date
Remove-Item "$out\events.txt" -ErrorAction SilentlyContinue
function Ev($name) { $s = ((Get-Date) - $t0).TotalSeconds; "$([math]::Round($s,1)) $name" | Add-Content "$out\events.txt"; "$([math]::Round($s,1)) $name" }
Start-Sleep 2

if ($Part -eq "horde") {
  Ev "start"
  foreach ($c in $cl) {
    Ev "join $c"
    Cmd $c 'T2C.join("127.0.0.1"); return "join"' 1
    WaitIn $c
    Ev "in $c"
    Start-Sleep 2
  }
  Start-Sleep 3
  Gather; God
  Ev "together"
  Start-Sleep 7
  Cmd A 'T2C.menuTab("coop"); T2C.menuOpen(); return "menu"' 0
  Ev "menu"
  Start-Sleep 6
  Cmd A 'T2C.menuClose(); return "c"' 0
  # the fight: everyone fires at the nearest enemy (they come to us); EXTRAS resupply keeps the guns loaded
  Ev "fight"
  for ($n = 0; $n -lt 5; $n++) {
    foreach ($i in @("A") + $cl) { Cmd $i 'return T2C.shootNearest(10)' 0 }
    Start-Sleep 1
    God
  }
  Ev "fightend"
  # down + revive next to the host
  $hl = (Q A ($hostPawn + ' local l=hp:K2_GetActorLocation(); return string.format("%.0f|%.0f|%.0f", l.X, l.Y, l.Z)') 1) -split "\|"
  Gather 260
  Cmd C "local p=T2C.client.pawn; p:SetInvulnerableState(false); return 'v'" 0
  Ev "down"
  Cmd C "T2C.client.pawn.Health=10; return 'hurt'" 9
  Ev "revived"
  God
  Start-Sleep 2
  # spectating: D far away goes down, watches partners (left click: next one), the host comes over
  Cmd D "local p=T2C.client.pawn; p:SetInvulnerableState(false); p:K2_SetActorLocation(T2C.freeSpotNear(p, 10), false, {}, true); return 'far'" 2
  Ev "spectate"
  Cmd D "T2C.client.pawn.Health=10; return 'hurt'" 4
  $pd = GamePid D
  & "$D\key.ps1" -ProcId $pd -Click -HoldMs 120 -X 480 -Y 270 | Out-Null; Start-Sleep 3
  & "$D\key.ps1" -ProcId $pd -Click -HoldMs 120 -X 480 -Y 270 | Out-Null; Start-Sleep 3
  Ev "hostgoes"
  Cmd A ($hostPawn + " for _,pc in ipairs(FindAllOf('PlayerController')) do local d=T2C.downed[pc:GetFName():ToString()]; if d and d.down and pc.Pawn:IsValid() then local l=pc.Pawn:K2_GetActorLocation(); hp:K2_SetActorLocation({X=l.X-100,Y=l.Y,Z=l.Z+20}, false, {}, true) end end; return 'go'") 10
  Ev "revived2"
  God
  Start-Sleep 3
  # everyone down far apart -> the arena restarts for everybody
  Ev "wipe"
  $k = 0
  foreach ($c in $cl) { $k++; Cmd $c "local p=T2C.client.pawn; p:SetInvulnerableState(false); p:K2_SetActorLocation({X=($($hl[0])+1500*$k),Y=($($hl[1])+600),Z=($($hl[2])+60)}, false, {}, true); p.Health=10; return 'down'" 0 }
  Start-Sleep 4
  Cmd A ($hostPawn + ' T2C.devGod=false; hp:SetInvulnerableState(false); hp.Health=10; return "down"') 30
  Cmd A 'T2C.devGod=true; pcall(T2C.stopLoadingScreen); return "ok"' 2
  foreach ($c in $cl) { WaitIn $c 10 }
  Ev "restarted"
  Start-Sleep 3
  Gather; God
  Ev "back"
  Start-Sleep 6
} elseif ($Part -eq "campaign") {
  Ev "join"
  foreach ($c in $cl) { Cmd $c 'T2C.join("127.0.0.1"); return "join"' 1 }
  foreach ($c in $cl) { WaitIn $c }
  Start-Sleep 3
  Gather; God
  Ev "together"
  Start-Sleep 6
  # the hub elevator with all four on it
  Cmd A ($hostPawn + ' hp:K2_SetActorLocation({X=-6640,Y=10050,Z=760}, false, {}, true); return "on"') 0
  $k = 0
  foreach ($c in $cl) { $k++; Cmd $c "T2C.client.pawn:K2_SetActorLocation({X=(-6790+100*$k),Y=9780,Z=760}, false, {}, true); return 'on'" 0 }
  Start-Sleep 2
  FaceAll
  Ev "elevator"
  Cmd A 'FindFirstOf("BP_CultistHubElevator_C"):TravelDown(); return "down"' 22
  FaceAll
  Ev "elevatordown"
  Start-Sleep 4
  Ev "restart"
  Cmd A 'local L=StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C"); local w=FindFirstOf("PlayerController"):GetWorld(); L["Trepang Restart Level"](L, w, w); return "travel"' 32
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 1
  foreach ($c in $cl) { WaitIn $c 25 }
  Start-Sleep 2
  Gather; God
  Ev "back"
  Start-Sleep 6
} else {
  Ev "mission"
  Start-Sleep 5
  Ev "end"
  Cmd A 'local w=FindFirstOf("PlayerController"):GetWorld(); for i=1,#w.StreamingLevels do local s=w.StreamingLevels[i]; pcall(function() s:SetShouldBeLoaded(true) end) end; return "all"' 12
  Cmd A ($hostPawn + ' for _,t in ipairs(FindAllOf("Trigger_EndLevel_C") or {}) do t.TriggerDisabled=false; t:TryTrigger(hp, {}); return "fired" end; return "none"') 30
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
  foreach ($c in $cl) { WaitIn $c 25 }
  Start-Sleep 2
  Gather
  Ev "safehouse"
  Start-Sleep 9
}
Ev "stop"
$xOff = 'for _,e in ipairs(T2C.extrasSpec) do T2C.extras[e.key]=e.vals[1] end; T2C.saveExtras(); return "x off"'
foreach ($i in @("A") + $cl) { Cmd $i $xOff 1 }
Stop-Process -Id $rec.Id -ErrorAction SilentlyContinue
Start-Sleep 1
if (-not $rec.HasExited) { $rec.WaitForExit() }
"recorded $out"
} finally { PutClaudeBack }
