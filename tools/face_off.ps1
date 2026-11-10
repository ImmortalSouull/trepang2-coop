# Put the client 350 units in front of the host, both looking at each other, and screenshot both.
# Usage: face_off.ps1 [-Dist 350] [-Tag name]
param([int]$Dist = 350, [string]$Tag = "face")
$D = $PSScriptRoot
$shots = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
$getHost = 'local pc; for _,c in ipairs(FindAllOf("PlayerController")) do if c:IsLocalController() then pc=c end end; '
$r = & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd ($getHost + 'pc:ClientSetRotation({Pitch=0,Yaw=0,Roll=0},false); local l=pc.Pawn:K2_GetActorLocation(); return string.format("HOSTPOS %.1f %.1f %.1f", l.X, l.Y, l.Z)') -Wait 2 -Grep "HOSTPOS"
$m = [regex]::Match(($r | Out-String), 'HOSTPOS (\S+) (\S+) (\S+)')
$x = [double]$m.Groups[1].Value + $Dist; $y = $m.Groups[2].Value; $z = $m.Groups[3].Value
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd ($getHost + "T2C.client.pawn:K2_SetActorLocation({X=$x,Y=$y,Z=$z},false,{},true); pc:ClientSetRotation({Pitch=0,Yaw=180,Roll=0},false); return 'placed'") -Wait 3 | Out-Null
foreach ($p in (Get-Process CPPFPS-Win64-Shipping)) {
  $t = if ($p.Path -like "*Trepang2_B*") { "B" } else { "A" }
  & "$D\shot.ps1" -ProcId $p.Id -Out "$shots\$Tag$t.png" | Out-Null
}
"shots: $shots\$Tag[A|B].png"
