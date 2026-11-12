# Showcase take for v0.9.21 (new features). Two parts:
#   coop  - host A (left) + partner B (right) on a Horde arena: F4 tabs, EXTRAS, regen, resupply, kills,
#           randomizer, F6 shop (partner), F6 weapon mods, arena change + partner back
#   safe  - host A alone in the safehouse: F6 - missions, outfit, combat simulator, cheats
# Writes raw.mkv + events.txt into C:\Users\PC\trepang2-coop-work\caps\<take>.
# The Claude window is moved to the right edge while recording (still topmost) and put back after.
param([string]$Take = "v0921", [ValidateSet("coop", "safe")][string]$Part = "coop", [int]$Seconds = 200)
$D = $PSScriptRoot
$out = "C:\Users\PC\trepang2-coop-work\caps\$Take-$Part"
New-Item -ItemType Directory -Force $out | Out-Null
$ff = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName
if (-not ("WSC" -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WSC { [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }
"@
}
$claude = Get-Process Claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$saved = $null
if ($claude) {
  $saved = New-Object WSC+R; [WSC]::GetWindowRect($claude.MainWindowHandle, [ref]$saved) | Out-Null
  [WSC]::SetWindowPos($claude.MainWindowHandle, [IntPtr](-1), 2600, 0, 840, 1400, 0x40) | Out-Null
}
function PutClaudeBack {
  if ($claude -and $saved) {
    [WSC]::SetWindowPos($claude.MainWindowHandle, [IntPtr](-1), $saved.L, $saved.T, $saved.Rr - $saved.L, $saved.B - $saved.T, 0x40) | Out-Null
  }
}
function Cmd($inst, $lua, $wait = 1) { & "$D\t2.ps1" -Inst $inst -Mod T2Coop -Cmd $lua -Wait $wait | Out-Null }
$myPawn = 'local me; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then me=x end end; local p=me.Pawn; if T2C.joined and T2C.client and T2C.client.pawn then p=T2C.client.pawn end;'
$face = 'local me; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then me=x end end; local other; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:GetFullName()~=me.Pawn:GetFullName() and not p.bHidden then other=p end end; if not other then return "none" end; local cam=me.PlayerCameraManager:GetCameraLocation(); local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); me:SetControlRotation(KML:FindLookAtRotation(cam, other:K2_GetActorLocation())); return "face"'

& "$D\deploy.ps1" | Out-Null
try {
if ($Part -eq "coop") {
  & "$D\launch.ps1" -Which A,B -Kill | Out-Null
  Start-Sleep 5
  Cmd A "T2C.devGod=true; T2C.host('/Game/Maps/HordeMode/Horde_Killhouse'); return 'host'" 42
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
  Cmd B 'T2C.join("127.0.0.1"); return "join"' 25
  Cmd B 'pcall(T2C.stopLoadingScreen); return "ok"' 4
  Cmd B 'local p=T2C.client.pawn; local l=p:K2_GetActorLocation(); p:K2_SetActorLocation({X=l.X+450,Y=l.Y+120,Z=l.Z+20}, false, {}, true); return "moved"' 1
  Cmd A $face 0; Cmd B $face 1
} else {
  & "$D\launch.ps1" -Which A -Kill | Out-Null
  Start-Sleep 30
  Cmd A 'local K=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"); local pc=FindFirstOf("PlayerController"); K:ExecuteConsoleCommand(pc:GetWorld(),"open SafeHouse_Persistent",pc); return "open"' 50
  foreach ($i in 1..3) { Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 5 }
}
$procs = Get-Process CPPFPS-Win64-Shipping
$A = ($procs | Where-Object Path -notlike "*Trepang2_B*").Id
$B = ($procs | Where-Object Path -like "*Trepang2_B*").Id

$size = if ($Part -eq "coop") { "2590x770" } else { "1290x770" }
$rec = Start-Process $ff -ArgumentList "-y -f gdigrab -framerate 30 -offset_x 0 -offset_y 0 -video_size $size -draw_mouse 0 -i desktop -t $Seconds -c:v libx264 -preset ultrafast -crf 20 -g 15 `"$out\raw.mkv`"" -PassThru -WindowStyle Hidden
$t0 = Get-Date
Remove-Item "$out\events.txt" -ErrorAction SilentlyContinue
function Ev($name) { $s = ((Get-Date) - $t0).TotalSeconds; "$([math]::Round($s,1)) $name" | Add-Content "$out\events.txt" }
Start-Sleep 2

if ($Part -eq "coop") {
  # EXTRAS start from the game's own values (the clicks below then land on the shown settings)
  Cmd A 'for _,e in ipairs(T2C.extrasSpec) do T2C.extras[e.key]=e.vals[1] end; T2C.saveExtras(); return "reset"' 1
  Cmd B 'for _,e in ipairs(T2C.extrasSpec) do T2C.extras[e.key]=e.vals[1] end; return "reset"' 0
  # F4 in three tabs
  Ev "tabs"
  Cmd A 'T2C.menuTab("coop"); T2C.menuOpen(); return "m"' 3
  Cmd A 'T2C.menuTab("look"); return "m"' 3
  Cmd A 'T2C.menuTab("extras"); return "m"' 2
  # EXTRAS: click through the settings
  Ev "extras"
  Cmd A 'local keys={"regen","regen","regen","armor","armor","armor","resupply","resupply","killsupply","execheal","execheal","keepmods","keepcheats","random"}; local i=0; T2C.every(450, function() i=i+1; local k=keys[i]; if not k then return true end; T2C.extraNext(k,1) end); return "clicks"' 7
  Start-Sleep 2
  Cmd A 'T2C.extras.random="0"; T2C.saveExtras(); T2C.menuClose(); return "c"' 1
  Cmd B 'T2C.extras.regen="100"; T2C.extras.armor="300"; return "b"' 0
  Cmd A $face 0; Cmd B $face 1
  # health regen to full
  Ev "regen"
  Cmd A ($myPawn + ' p.Health=90; return "hp"') 0
  Start-Sleep 9
  # resupply: empty gun and grenades, then a resupply
  Ev "resupply"
  Cmd A ($myPawn + ' p.CurrentWeapon.CurrentAmmo=0; for i=1,p.GrenadeInventory:GetArrayNum() do p.GrenadeInventory[i].NumGrenades=0 end; return "e"') 2
  Cmd A ($myPawn + ' T2C.resupply(p,"show"); return "r"') 2
  Cmd A ($myPawn + ' T2C.resupply(p,"show"); return "r"') 3
  # resupply on kill: the host takes out enemies
  Ev "kills"
  for ($k = 0; $k -lt 3; $k++) {
    Cmd A 'local pc; for _,c in ipairs(FindAllOf("PlayerController")) do if c:IsLocalController() then pc=c end end; local GS=StaticFindObject("/Script/Engine.Default__GameplayStatics"); for _,npc in ipairs(T2C.allOf("/Game/Blueprint/AI/BaseNPC.BaseNPC_C")) do if not npc.bIsDead then GS:ApplyDamage(npc, 5000, pc, pc.Pawn, nil); return "k" end end; return "none"' 2
  }
  Start-Sleep 1
  # randomizer: new colours / mods on the guns
  Ev "random"
  foreach ($k in 1..4) { Cmd A 'T2C.extras.random="1"; T2C.xSeen={}; return "r"' 2 }
  Cmd A 'T2C.extras.random="0"; return "r"' 1
  # F6 on the partner: the Horde shop
  Ev "f6shop"
  Cmd B 'T2C.onKey("quick"); return "q"' 3
  Cmd B 'local l=T2C.quickList(); T2C.menuClose(); for _,q in ipairs(l) do if q.name=="SHOP" then T2C.quickRun=q.fn end end; return "s"' 5
  # F6 on the host: weapon mods
  Ev "f6mods"
  Cmd A 'T2C.onKey("quick"); return "q"' 2
  Cmd A 'local l=T2C.quickList(); T2C.menuClose(); T2C.quickRun=l[1].fn; return "w"' 5
  Cmd A ($myPawn + ' p:BPCloseWeaponCustomizeMenu(); return "c"') 1
  # arena change: the partner gets back in on their own
  Ev "travel"
  Cmd A "T2C.host('Horde_Atrium'); return 'host'" 36
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 1
  for ($i = 0; $i -lt 12; $i++) {
    $r = & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'return "B "..T2C.where()' -Wait 2 -Grep "cmd ok"
    if ("$r" -match "PlayerBP_C") { break }
    Start-Sleep 2
  }
  Cmd B 'pcall(T2C.stopLoadingScreen); return "ok"' 2
  Cmd A $face 0; Cmd B $face 1
  Ev "back"
  Start-Sleep 6
} else {
  Ev "f6safe"
  Cmd A 'T2C.onKey("quick"); return "q"' 3
  foreach ($name in "MISSIONS","OUTFIT","COMBAT SIMULATOR","CHEATS") {
    Cmd A "local l=T2C.quickList(); T2C.menuClose(); for _,q in ipairs(l) do if q.name=='$name' then T2C.quickRun=q.fn end end; return 'go'" 0
    Ev ("s_" + $name)
    Start-Sleep 5
    & "$D\key.ps1" -ProcId $A -Vk 0x1B -HoldMs 60 -Focus | Out-Null
    Start-Sleep 1
    & "$D\key.ps1" -ProcId $A -Vk 0x1B -HoldMs 60 | Out-Null
    Start-Sleep 1
    if ($name -ne "CHEATS") { Cmd A 'T2C.onKey("quick"); return "q"' 2 }
  }
}
Ev "end"
Stop-Process -Id $rec.Id -ErrorAction SilentlyContinue
Start-Sleep 1
if (-not $rec.HasExited) { $rec.WaitForExit() }
"recorded $out"
} finally { PutClaudeBack }
