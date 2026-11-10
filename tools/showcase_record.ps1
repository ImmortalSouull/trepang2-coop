# Record a showcase take: two game windows (host A left, client B right) captured from the desktop
# with ffmpeg while this script drives the scenario. Writes raw.mp4 + events.txt (seconds since start)
# + rects.txt (client areas of both windows) into C:\Users\PC\trepang2-coop-work\caps\<take>.
param([string]$Take = "beta1", [int]$Seconds = 125)
$D = $PSScriptRoot
$out = "C:\Users\PC\trepang2-coop-work\caps\$Take"
New-Item -ItemType Directory -Force $out | Out-Null
$ff = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe | Select-Object -First 1).FullName

& "$D\deploy.ps1" | Out-Null
& "$D\launch.ps1" -Which A,B -Kill | Out-Null
Start-Sleep 5
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "T2C.devGod=true; T2C.host('/Game/Maps/HordeMode/Horde_Killhouse'); return 'host'" -Wait 42 | Out-Null
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'FindFirstOf("GameInstanceBP_C"):ForceStopLoadingScreen(); return "ok"' -Wait 2 | Out-Null

# client rectangles on screen
Add-Type @"
using System; using System.Runtime.InteropServices;
public class CR { [StructLayout(LayoutKind.Sequential)] public struct R { public int L,T,Rr,B; } [StructLayout(LayoutKind.Sequential)] public struct P { public int X,Y; }
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r); [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p); }
"@
$procs = Get-Process CPPFPS-Win64-Shipping
$rects = foreach ($p in $procs) {
  $r = New-Object CR+R; [CR]::GetClientRect($p.MainWindowHandle, [ref]$r) | Out-Null
  $pt = New-Object CR+P; [CR]::ClientToScreen($p.MainWindowHandle, [ref]$pt) | Out-Null
  $tag = if ($p.Path -like "*Trepang2_B*") { "B" } else { "A" }
  "$tag $($pt.X) $($pt.Y) $($r.Rr) $($r.B)"
}
$rects | Set-Content "$out\rects.txt"
$A = ($procs | Where-Object Path -notlike "*Trepang2_B*").Id
$B = ($procs | Where-Object Path -like "*Trepang2_B*").Id

$rec = Start-Process $ff -ArgumentList "-y -f gdigrab -framerate 30 -offset_x 0 -offset_y 0 -video_size 2590x770 -draw_mouse 0 -i desktop -t $Seconds -c:v libx264 -preset ultrafast -crf 20 -g 15 `"$out\raw.mp4`"" -PassThru -WindowStyle Hidden
$t0 = Get-Date
function Ev($name) { $s = ((Get-Date) - $t0).TotalSeconds; "$([math]::Round($s,1)) $name" | Add-Content "$out\events.txt" }
Remove-Item "$out\events.txt" -ErrorAction SilentlyContinue
Start-Sleep 2

Ev "join"
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'T2C.join("127.0.0.1"); return "join"' -Wait 22 | Out-Null
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'FindFirstOf("GameInstanceBP_C"):ForceStopLoadingScreen(); return "ok"' -Wait 3 | Out-Null
Ev "joined"

# face each other a few meters apart: host looks at the partner, partner looks at the host
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'local p=T2C.client.pawn; local l=p:K2_GetActorLocation(); p:K2_SetActorLocation({X=l.X+500,Y=l.Y+150,Z=l.Z+20}, false, {}, true); return "moved"' -Wait 1 | Out-Null
$face = 'local me; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then me=x end end; local other; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:GetFullName()~=me.Pawn:GetFullName() and not p.bHidden then other=p end end; local cam=me.PlayerCameraManager:GetCameraLocation(); local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); me:SetControlRotation(KML:FindLookAtRotation(cam, other:K2_GetActorLocation())); return "face"'
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $face -Wait 1 | Out-Null
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd $face -Wait 1 | Out-Null
Ev "facing"
Start-Sleep 4
& "$D\key.ps1" -ProcId $B -Vk 0x57 -HoldMs 1500
Ev "walked"
Start-Sleep 3

# fight: both look at the nearest enemy and shoot
$aim = 'local me; for _,x in ipairs(FindAllOf("PlayerController")) do if x:IsLocalController() then me=x end end; local pcls=StaticFindObject("/Script/CPPFPS.BasePlayer"); local cam=me.PlayerCameraManager:GetCameraLocation(); local best,bd; for _,c in ipairs(T2C.allOf("/Script/CPPFPS.BaseCharacter")) do if not c:IsA(pcls) and not c.bIsDead then local l=c:K2_GetActorLocation(); local d=(l.X-cam.X)^2+(l.Y-cam.Y)^2; if not bd or d<bd then best,bd=c,d end end end; if not best then return "none" end; local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); local l=best:K2_GetActorLocation(); me:SetControlRotation(KML:FindLookAtRotation(cam, {X=l.X,Y=l.Y,Z=l.Z+30})); return "aim"'
Ev "fight"
for ($k = 0; $k -lt 4; $k++) {
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $aim -Wait 0 | Out-Null
  & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd $aim -Wait 1 | Out-Null
  for ($i = 0; $i -lt 3; $i++) { & "$D\key.ps1" -ProcId $B -Click -HoldMs 50; & "$D\key.ps1" -ProcId $A -Click -HoldMs 50; Start-Sleep -Milliseconds 250 }
}
# a guaranteed partner headshot kill (money)
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'local pcls=StaticFindObject("/Script/CPPFPS.BasePlayer"); for _,c in ipairs(T2C.allOf("/Script/CPPFPS.BaseCharacter")) do if not c:IsA(pcls) and not c.bIsDead then local l=c:K2_GetActorLocation(); local cam={X=l.X+300,Y=l.Y,Z=l.Z+40}; local KML=StaticFindObject("/Script/Engine.Default__KismetMathLibrary"); local r=KML:FindLookAtRotation(cam,{X=l.X,Y=l.Y,Z=l.Z+72}); T2C.toServer("SH", string.format("%.1f|%.1f|%.1f",cam.X,cam.Y,cam.Z), string.format("%.2f|%.2f",r.Yaw,r.Pitch), 1, "/Game/Weapon/Pistol/BP_Pistol.BP_Pistol_C"); return "hs" end end; return "none"' -Wait 3 | Out-Null
Ev "money"
Start-Sleep 3

# down & revive (host stands next to the partner)
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'local pc=T2C.client.pawn.Controller; local p=T2C.client.pawn; local hl; for _,x in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if x:GetFName():ToString()=="PlayerBP_2" then hl=x:K2_GetActorLocation() end end; p:K2_SetActorLocation({X=hl.X+180,Y=hl.Y,Z=hl.Z+20}, false, {}, true); return "near host"' -Wait 1 | Out-Null
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $face -Wait 0 | Out-Null
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd $face -Wait 1 | Out-Null
Ev "down"
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'local p=T2C.client.pawn; p:SetInvulnerableState(false); p.Health=20; return "down"' -Wait 7 | Out-Null
Ev "revived"
Start-Sleep 4

# partner far away: marker with distance
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'local p=T2C.client.pawn; local l=p:K2_GetActorLocation(); p:K2_SetActorLocation({X=l.X+1400,Y=l.Y-500,Z=l.Z+20}, false, {}, true); return "far"' -Wait 1 | Out-Null
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $face -Wait 1 | Out-Null
Ev "marker"
Start-Sleep 6
Ev "end"
$rec.WaitForExit()
"recorded $out"
