# 360-degree look at a player model: the observer stands still, the model turns in steps,
# frames are cropped, brightened and put on one contact sheet.
#   -Who host  : the host's pawn as the guest (B) sees it
#   -Who guest : the guest's puppet as the host (A) sees it
# Usage: turntable.ps1 -Who host|guest [-Steps 8] [-Dist 260] [-Out sheet.png] [-Gain 1.8]
param([string]$Who = "host", [int]$Steps = 8, [int]$Dist = 260, [string]$Out = "", [double]$Gain = 1.8)
$D = $PSScriptRoot
$shots = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
if (-not $Out) { $Out = "$shots\turn_$Who.png" }
$getLocal = 'local pc; for _,c in ipairs(FindAllOf("PlayerController")) do if c:IsLocalController() then pc=c end end; '
$getRemote = 'local rp; for _,c in ipairs(FindAllOf("PlayerController")) do if not c:IsLocalController() then rp=c end end; '

# host position = centre of the scene
$r = & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd ($getLocal + 'local l=pc.Pawn:K2_GetActorLocation(); return string.format("HOSTPOS %.1f %.1f %.1f", l.X, l.Y, l.Z)') -Wait 2 -Grep "HOSTPOS"
$m = [regex]::Match(($r | Out-String), 'HOSTPOS (\S+) (\S+) (\S+)')
$hx = [double]$m.Groups[1].Value; $hy = [double]$m.Groups[2].Value; $hz = [double]$m.Groups[3].Value

if ($Who -eq "host") {
  # guest stands in front of the host and looks at it
  $gx = $hx + $Dist
  & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd ($getLocal + "T2C.client.pawn:K2_SetActorLocation({X=$gx,Y=$hy,Z=$hz},false,{},true); pc:ClientSetRotation({Pitch=-8,Yaw=180,Roll=0},false); return 'cam'") -Wait 2 | Out-Null
  $camInst = "B"
} else {
  # host looks at its partner's puppet, which we place and turn by hand (pose updates paused)
  $gx = $hx + $Dist
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd ($getLocal + $getRemote + "T2C.devNoPose=true; pc:ClientSetRotation({Pitch=-8,Yaw=0,Roll=0},false); rp.Pawn:K2_SetActorLocation({X=$gx,Y=$hy,Z=$hz},false,{},true); return 'cam'") -Wait 2 | Out-Null
  $camInst = "A"
}
$proc = Get-Process CPPFPS-Win64-Shipping | Where-Object { ($camInst -eq "B") -eq ($_.Path -like "*Trepang2_B*") } | Select-Object -First 1

$frames = @()
for ($i = 0; $i -lt $Steps; $i++) {
  $yaw = [int](180 + 360 * $i / $Steps)   # 0 = facing the camera
  if ($Who -eq "host") {
    & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd ($getLocal + "pc.Pawn:K2_SetActorRotation({Pitch=0,Yaw=$($yaw - 180),Roll=0},false); pc:ClientSetRotation({Pitch=0,Yaw=$($yaw - 180),Roll=0},false); return 'turn'") -Wait 1 | Out-Null
  } else {
    & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd ($getRemote + "rp.Pawn:K2_SetActorRotation({Pitch=0,Yaw=$($yaw - 180),Roll=0},false); rp:SetControlRotation({Pitch=0,Yaw=$($yaw - 180),Roll=0}); return 'turn'") -Wait 1 | Out-Null
  }
  Start-Sleep -Milliseconds 400
  $f = "$shots\tt_$Who$i.png"
  & "$D\shot.ps1" -ProcId $proc.Id -Out $f | Out-Null
  $frames += $f
}
if ($Who -eq "guest") { & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'T2C.devNoPose=false; return "ok"' -Wait 1 | Out-Null }

# contact sheet: centre crop of each frame, 4 per row
Add-Type -AssemblyName System.Drawing
$cw = 300; $ch = 420; $cols = 4; $rows = [math]::Ceiling($frames.Count / $cols)
$sheet = New-Object System.Drawing.Bitmap ($cw * $cols), ($ch * $rows)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$cm = New-Object System.Drawing.Imaging.ColorMatrix
$cm.Matrix00 = $Gain; $cm.Matrix11 = $Gain; $cm.Matrix22 = $Gain
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$attr.SetColorMatrix($cm)
$font = New-Object System.Drawing.Font "Arial", 14
for ($i = 0; $i -lt $frames.Count; $i++) {
  $src = [System.Drawing.Bitmap]::FromFile($frames[$i])
  $x = ($i % $cols) * $cw; $y = [math]::Floor($i / $cols) * $ch
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle $x, $y, $cw, $ch), 490, 150, $cw, $ch, [System.Drawing.GraphicsUnit]::Pixel, $attr)
  $g.DrawString("$([int](360 * $i / $Steps)) deg", $font, [System.Drawing.Brushes]::Yellow, $x + 6, $y + 6)
  $src.Dispose()
}
$sheet.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $sheet.Dispose()
"sheet: $Out"
