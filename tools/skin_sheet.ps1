# The guest (B) cycles through its looks with the F4 "LOOK" action; the host (A) photographs the
# guest's body (front and side) for each one. Result: one labelled contact sheet.
# Usage: skin_sheet.ps1 [-Count 17] [-Gain 2]
param([int]$Count = 17, [double]$Gain = 2, [string]$Out = "")
$D = $PSScriptRoot
$shotDir = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
if (-not $Out) { $Out = "$shotDir\skins_sheet.png" }
$pa = (Get-Process CPPFPS-Win64-Shipping | Where-Object { $_.Path -notlike "*Trepang2_B*" }).Id
$place = 'local pc,rp; for _,c in ipairs(FindAllOf("PlayerController")) do if c:IsLocalController() then pc=c else rp=c end end; T2C.devNoPose=true; local l=pc.Pawn:K2_GetActorLocation(); pc:ClientSetRotation({Pitch=-5,Yaw=0,Roll=0},false); rp.Pawn:K2_SetActorLocationAndRotation({X=l.X+260,Y=l.Y,Z=l.Z},{Pitch=0,Yaw=YAW,Roll=0},false,{},true); return "p"'
$frames = @()
for ($i = 0; $i -lt $Count; $i++) {
  $r = & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'T2C.press("nextlook"); return "x"' -Wait 4 -Grep "cmd ok"
  $name = ((& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'local k=T2C.skinById(T2C.mySkin); return "SKIN="..(k and k.name or "safehouse")' -Wait 1 -Grep "SKIN") -replace '.*SKIN=', '').Trim()
  foreach ($yaw in 180, 270) {
    & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $place.Replace("YAW", "$yaw") -Wait 1 | Out-Null
    Start-Sleep -Milliseconds 400
    $f = "$shotDir\skin_$i`_$yaw.png"
    & "$D\shot.ps1" -ProcId $pa -Out $f | Out-Null
    $frames += , @($f, $name)
  }
}
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'T2C.devNoPose=false; return "x"' -Wait 1 | Out-Null
Add-Type -AssemblyName System.Drawing
$cw = 220; $ch = 330; $cols = 8; $rows = [math]::Ceiling($frames.Count / $cols)
$sheet = New-Object System.Drawing.Bitmap ($cw * $cols), ($ch * $rows)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$cm = New-Object System.Drawing.Imaging.ColorMatrix
$cm.Matrix00 = $Gain; $cm.Matrix11 = $Gain; $cm.Matrix22 = $Gain
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$attr.SetColorMatrix($cm)
$font = New-Object System.Drawing.Font "Arial", 11
for ($i = 0; $i -lt $frames.Count; $i++) {
  $src = [System.Drawing.Bitmap]::FromFile($frames[$i][0])
  $x = ($i % $cols) * $cw; $y = [math]::Floor($i / $cols) * $ch
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle $x, $y, $cw, $ch), 530, 150, $cw, $ch, [System.Drawing.GraphicsUnit]::Pixel, $attr)
  $g.DrawString($frames[$i][1], $font, [System.Drawing.Brushes]::Yellow, $x + 4, $y + 4)
  $src.Dispose()
}
$sheet.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $sheet.Dispose()
"sheet: $Out"
