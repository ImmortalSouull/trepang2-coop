# One player really performs actions (keys sent to its window), the other watches from 320 units
# away; three frames of the watcher's view per action go on a labelled contact sheet.
#   -Actor B : the guest acts, the host watches its puppet      -Actor A : the host acts, the guest watches
# Usage: action_shots.ps1 [-Actor B] [-Actions idle,walk,sprint,crouch,crouchwalk,jump,slide,fire] [-Gain 2.2]
param([string]$Actor = "B", [string[]]$Actions = @("idle", "walk", "sprint", "crouch", "crouchwalk", "jump", "slide", "fire"),
      [double]$Gain = 2.2, [string]$Out = "")
$D = $PSScriptRoot
$shots = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
if (-not $Out) { $Out = "$shots\actions_$Actor.png" }
$Watcher = if ($Actor -eq "B") { "A" } else { "B" }
$getLocal = 'local pc; for _,c in ipairs(FindAllOf("PlayerController")) do if c:IsLocalController() then pc=c end end; local me = (T2C.client and T2C.client.pawn and T2C.client.pawn:IsValid()) and T2C.client.pawn or pc.Pawn; '
$keys = @{
  idle = @(); walk = @(0x57); sprint = @(0x57, 0xA0); crouch = @(0xA2); crouchwalk = @(0xA2, 0x57)
  jump = @(0x57, 0x20); slide = @(0x57, 0xA0, 0xA2)
}
# pause between key presses (crouch first, then walk; run first, then crouch = slide)
$gaps = @{ crouchwalk = 500; slide = 450 }
$procs = @{}
foreach ($p in Get-Process CPPFPS-Win64-Shipping) { $procs[$(if ($p.Path -like "*Trepang2_B*") { "B" } else { "A" })] = $p }

# scene centre = watcher position
$r = & "$D\t2.ps1" -Inst $Watcher -Mod T2Coop -Cmd ($getLocal + 'local l=me:K2_GetActorLocation(); return string.format("WPOS %.1f %.1f %.1f", l.X, l.Y, l.Z)') -Wait 2 -Grep "WPOS"
$m = [regex]::Match(($r | Out-String), 'WPOS (\S+) (\S+) (\S+)')
$wx = [double]$m.Groups[1].Value; $wy = [double]$m.Groups[2].Value; $wz = [double]$m.Groups[3].Value
& "$D\t2.ps1" -Inst $Watcher -Mod T2Coop -Cmd ($getLocal + 'pc:ClientSetRotation({Pitch=-5,Yaw=0,Roll=0},false); return "w"') -Wait 1 | Out-Null

& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'T2C.devNoEnemies=true; T2C.every(300, function() if not T2C.devNoEnemies then return true end; local pc=FindAllOf("PlayerController"); for _,c in ipairs(T2C.allOf("/Script/CPPFPS.BaseCharacter")) do if not c:IsA(StaticFindObject("/Script/CPPFPS.BasePlayer")) then pcall(function() c:K2_DestroyActor() end) end end end); return "clear"' -Wait 2 | Out-Null
$frames = @()
foreach ($a in $Actions) {
  # actor: 420 in front of the watcher, a little to the left, facing right (crosses the view)
  $ax = $wx + 420; $ay = $wy - 90
  & "$D\t2.ps1" -Inst $Actor -Mod T2Coop -Cmd ($getLocal + "me:K2_SetActorLocation({X=$ax,Y=$ay,Z=$wz},false,{},true); pc:ClientSetRotation({Pitch=0,Yaw=90,Roll=0},false); return 'placed'") -Wait 1 | Out-Null
  Start-Sleep -Milliseconds 600
  $job = $null
  $actorPid = $procs[$Actor].Id
  if ($a -eq "fire") {
    $job = Start-Job -ScriptBlock { param($k, $id) & $k -ProcId $id -Click -HoldMs 1200 } -ArgumentList "$D\key.ps1", $actorPid
  } elseif ($keys[$a].Count) {
    $gap = if ($gaps[$a]) { $gaps[$a] } else { 30 }
    $job = Start-Job -ScriptBlock { param($k, $id, $v, $gp) & $k -ProcId $id -Vks $v -HoldMs 1400 -GapMs $gp } -ArgumentList "$D\key.ps1", $actorPid, $keys[$a], $gap
  }
  Start-Sleep -Milliseconds $(if ($gaps[$a]) { 250 + $gaps[$a] * ($keys[$a].Count - 1) } else { 700 })
  for ($i = 0; $i -lt 3; $i++) {
    $f = "$shots\act_$Actor`_$a$i.png"
    & "$D\shot.ps1" -ProcId $procs[$Watcher].Id -Out $f | Out-Null
    $frames += , @($f, "$a $($i+1)")
    Start-Sleep -Milliseconds 220
  }
  if ($job) { Wait-Job $job -Timeout 10 | Out-Null; Remove-Job $job -Force }
  Start-Sleep -Milliseconds 300
}

& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'T2C.devNoEnemies=false; return "ok"' -Wait 1 | Out-Null
Add-Type -AssemblyName System.Drawing
$cw = 420; $ch = 330; $cols = 3; $rows = [math]::Ceiling($frames.Count / $cols)
$sheet = New-Object System.Drawing.Bitmap ($cw * $cols), ($ch * $rows)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$cm = New-Object System.Drawing.Imaging.ColorMatrix
$cm.Matrix00 = $Gain; $cm.Matrix11 = $Gain; $cm.Matrix22 = $Gain
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$attr.SetColorMatrix($cm)
$font = New-Object System.Drawing.Font "Arial", 15
for ($i = 0; $i -lt $frames.Count; $i++) {
  $src = [System.Drawing.Bitmap]::FromFile($frames[$i][0])
  $x = ($i % $cols) * $cw; $y = [math]::Floor($i / $cols) * $ch
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle $x, $y, $cw, $ch), 380, 190, $cw * 1.25, $ch * 1.25, [System.Drawing.GraphicsUnit]::Pixel, $attr)
  $g.DrawString($frames[$i][1], $font, [System.Drawing.Brushes]::Yellow, $x + 6, $y + 6)
  $src.Dispose()
}
$sheet.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $sheet.Dispose()
"sheet: $Out"
