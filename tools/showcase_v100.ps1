# Showcase takes for v1.0.0 (campaign co-op). Host A (left) + partner B (right), recorded side by side.
#   campaign  - KillCultists: partner joins the mission, elevator ride together, fall-off-the-map rescue,
#               level restart (partner back on their own)
#   ghostsend - KillGhosts: the mission ends, both arrive in the safehouse
#   credits   - the credits level for both
# Writes raw.mkv + events.txt into C:\Users\PC\trepang2-coop-work\caps\<take>-<part>.
# Campaign takes overwrite the campaign save: back it up first (see CLAUDE.md).
param([string]$Take = "v100", [ValidateSet("campaign", "ghostsend", "credits")][string]$Part = "campaign", [int]$Seconds = 150)
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
function WaitPartner($max = 20) {
  for ($i = 0; $i -lt $max; $i++) {
    # (no "press any key" from here: the mod does that itself)
    $r = & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'return "B "..T2C.where()' -Wait 3 -Grep "cmd ok"
    if ("$r" -match "PlayerBP_C") { return }
  }
}
$face = 'local me; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then me=x end end; local other; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:GetFullName()~=me.Pawn:GetFullName() and not p.bHidden then other=p end end; if not other then return "none" end; local cam=me.PlayerCameraManager:GetCameraLocation(); local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); me:SetControlRotation(KML:FindLookAtRotation(cam, other:K2_GetActorLocation())); return "face"'
$map = @{ campaign = "/Game/Maps/Campaign/Cultists/KillCultists_Persistent"; ghostsend = "/Game/Maps/Campaign/Ghosts/KillGhosts_Persistent"; credits = "/Game/Maps/Campaign/Credits/Credits_Persistent" }[$Part]

& "$D\deploy.ps1" | Out-Null
try {
& "$D\launch.ps1" -Which A,B -Kill | Out-Null
Start-Sleep 5
Cmd A "T2C.devGod=true; T2C.host('$map'); return 'host'" 42
Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
if ($Part -ne "campaign") {
  Cmd B 'T2C.join("127.0.0.1"); return "join"' 25
  WaitPartner
  Cmd A $face 0; Cmd B $face 1
}

$rec = Start-Process $ff -ArgumentList "-y -f gdigrab -framerate 30 -offset_x 0 -offset_y 0 -video_size 2590x770 -draw_mouse 0 -i desktop -t $Seconds -c:v libx264 -preset ultrafast -crf 20 -g 15 `"$out\raw.mkv`"" -PassThru -WindowStyle Hidden
$t0 = Get-Date
Remove-Item "$out\events.txt" -ErrorAction SilentlyContinue
function Ev($name) { $s = ((Get-Date) - $t0).TotalSeconds; "$([math]::Round($s,1)) $name" | Add-Content "$out\events.txt" }
Start-Sleep 2

if ($Part -eq "campaign") {
  Ev "join"
  Cmd B 'T2C.join("127.0.0.1"); return "join"' 1
  WaitPartner
  Cmd A $face 0; Cmd B $face 1
  Ev "together"
  Start-Sleep 6
  # the hub elevator: both on it, the host's story sends it down
  Cmd A 'local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; p:K2_SetActorLocation({X=-6640,Y=10050,Z=760}, false, {}, true); return "on"' 0
  Cmd B 'T2C.client.pawn:K2_SetActorLocation({X=-6640,Y=9750,Z=760}, false, {}, true); return "on"' 2
  Cmd A $face 0; Cmd B $face 1
  Ev "elevator"
  Cmd A 'FindFirstOf("BP_CultistHubElevator_C"):TravelDown(); return "down"' 22
  Cmd A $face 0; Cmd B $face 1
  Ev "elevatordown"
  Start-Sleep 4
  # fall off the map: back to the host
  Ev "fall"
  Cmd B 'local w=FindFirstOf("WorldSettings"); local p=T2C.client.pawn; local l=p:K2_GetActorLocation(); w.KillZ=l.Z-5000; T2C.killZLevel=nil; p:K2_SetActorLocation({X=l.X+2500,Y=l.Y,Z=l.Z-1200}, false, {}, true); return "drop"' 9
  Cmd A $face 0; Cmd B $face 1
  Ev "rescued"
  Start-Sleep 4
  # the game restarts the level: the partner comes back on their own
  Ev "restart"
  Cmd A 'local L=StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C"); local w=FindFirstOf("PlayerController"):GetWorld(); L["Trepang Restart Level"](L, w, w); return "travel"' 32
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 1
  WaitPartner 25
  Cmd A $face 0; Cmd B $face 1
  Ev "back"
  Start-Sleep 6
} elseif ($Part -eq "ghostsend") {
  Ev "mission"
  Start-Sleep 4
  Ev "end"
  Cmd A 'local w=FindFirstOf("PlayerController"):GetWorld(); for i=1,#w.StreamingLevels do local s=w.StreamingLevels[i]; pcall(function() s:SetShouldBeLoaded(true) end) end; return "all"' 12
  Cmd A 'local p; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then p=x.Pawn end end; for _,t in ipairs(FindAllOf("Trigger_EndLevel_C") or {}) do t.TriggerDisabled=false; t:TryTrigger(p, {}); return "fired" end; return "none"' 30
  Cmd A 'pcall(T2C.stopLoadingScreen); return "ok"' 2
  WaitPartner 25
  Cmd A $face 0; Cmd B $face 1
  Ev "safehouse"
  Start-Sleep 8
} else {
  Ev "credits"
  Start-Sleep 14
}
Ev "stop"
Stop-Process -Id $rec.Id -ErrorAction SilentlyContinue
Start-Sleep 1
if (-not $rec.HasExited) { $rec.WaitForExit() }
"recorded $out"
} finally { PutClaudeBack }
