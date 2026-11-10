# Crop a region of a PNG, scale it up and brighten it (for looking at dark details in screenshots).
# Usage: crop.ps1 -In a.png -Out b.png -X 520 -Y 330 -W 260 -H 260 [-Scale 2] [-Gain 3]
param([string]$In, [string]$Out, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 2, [double]$Gain = 3)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile($In)
$dst = New-Object System.Drawing.Bitmap ($W * $Scale), ($H * $Scale)
$g = [System.Drawing.Graphics]::FromImage($dst)
$m = New-Object System.Drawing.Imaging.ColorMatrix
$m.Matrix00 = $Gain; $m.Matrix11 = $Gain; $m.Matrix22 = $Gain
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$attr.SetColorMatrix($m)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, ($W * $Scale), ($H * $Scale)), $X, $Y, $W, $H, [System.Drawing.GraphicsUnit]::Pixel, $attr)
$dst.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $dst.Dispose(); $src.Dispose()
