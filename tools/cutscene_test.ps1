# With A hosting and B joined: start a level cutscene on the host the way the game does
# (BaseGameMode PlayLevelCutscene) and screenshot both games side by side a few times.
# Usage: cutscene_test.ps1 [-Name <LevelSequenceActor name, default: first found>] [-Start 0] [-Shots 4] [-Every 3]
param([string]$Name = "", [double]$Start = 0, [double]$Delay = 0, [int]$Shots = 4, [double]$Every = 3, [string]$Tag = "cs")
$D = $PSScriptRoot
$shotDir = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
$pick = if ($Name) { "a:GetFName():ToString()=='$Name'" } else { "true" }
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "local gm=FindFirstOf('BaseGameMode_C'); local seq; for _,a in ipairs(FindAllOf('LevelSequenceActor') or {}) do if not seq and $pick then seq=a end end; if not seq then return 'no sequence' end; gm:PlayLevelCutscene(seq, $Start); return 'playing '..seq:GetFName():ToString()" -Wait 1 -Grep "cmd ok|error"
if ($Delay -gt 0) { Start-Sleep -Milliseconds ([int]($Delay * 1000)) }
$procs = @{}
foreach ($p in Get-Process CPPFPS-Win64-Shipping) { $procs[$(if ($p.Path -like "*Trepang2_B*") { "B" } else { "A" })] = $p }
Add-Type -AssemblyName System.Drawing
$w = 640; $h = 360
$sheet = New-Object System.Drawing.Bitmap ($w * 2), ($h * $Shots)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$font = New-Object System.Drawing.Font "Arial", 14
for ($i = 0; $i -lt $Shots; $i++) {
  Start-Sleep -Milliseconds ([int]($Every * 1000))
  foreach ($k in "A", "B") {
    $f = "$shotDir\$Tag$k$i.png"
    & "$D\shot.ps1" -ProcId $procs[$k].Id -Out $f | Out-Null
    $src = [System.Drawing.Bitmap]::FromFile($f)
    $x = $(if ($k -eq "A") { 0 } else { $w })
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle $x, ($i * $h), $w, $h))
    $g.DrawString("$(if ($k -eq 'A') { 'HOST' } else { 'GUEST' }) $([math]::Round(($i + 1) * $Every, 1))s", $font, [System.Drawing.Brushes]::Yellow, $x + 6, $i * $h + 6)
    $src.Dispose()
  }
}
$out = "$shotDir\$Tag`_sheet.png"
$sheet.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $sheet.Dispose()
"sheet: $out"
