# Campaign co-op test: host a campaign level on A, join from B, then let the GAME travel
# (its own "restart level" by default) and check that B ends up back with the host.
# Usage: test_campaign.ps1 [-Map /Game/Maps/...] [-Travel restart|none|'<lua on A>'] [-NoRestart]
param(
  [string]$Map = "/Game/Maps/Campaign/Cultists/KillCultists_Persistent",
  [string]$Travel = "restart",
  [switch]$NoRestart
)
$D = $PSScriptRoot
$shots = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$crashBefore = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
$logA = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log"
$logB = "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log"
$stop = 'pcall(T2C.stopLoadingScreen)'

& "$D\deploy.ps1" | Out-Null
if (-not $NoRestart) { & "$D\launch.ps1" -Which A,B -Kill | Out-Null; Start-Sleep 5 }

& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "T2C.devGod=true; T2C.host('$Map'); return 'host'" -Wait 40 | Out-Null
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "$stop; return 'ok'" -Wait 2 | Out-Null
"listen: " + [bool](netstat -ano -p UDP | Select-String ":7777")
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'T2C.join("127.0.0.1"); return "join"' -Wait 30 | Out-Null
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd "$stop; return 'ok'" -Wait 3 | Out-Null
"--- before travel"
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'return "A: "..T2C.where()' -Wait 2 -Grep "cmd ok"
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'return "B: "..T2C.where()' -Wait 2 -Grep "cmd ok"

if ($Travel -ne "none") {
  $lua = $Travel
  if ($Travel -eq "restart") {
    $lua = 'local L=StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C"); local w=FindFirstOf("PlayerController"):GetWorld(); L["Trepang Restart Level"](L, w, w); return "travel"'
  }
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $lua -Wait 40 | Out-Null
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "$stop; return 'ok'" -Wait 2 | Out-Null
  & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd "$stop; return 'ok'" -Wait 25 | Out-Null
  "--- after travel"
  "listen: " + [bool](netstat -ano -p UDP | Select-String ":7777")
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'return "A: "..T2C.where()' -Wait 2 -Grep "cmd ok"
  & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'return "B: "..T2C.where()' -Wait 2 -Grep "cmd ok"
}
"--- A log"
Select-String $logA -Pattern "\[T2Coop\]" | Select-Object -Last 14 | ForEach-Object Line
"--- B log"
Select-String $logB -Pattern "\[T2Coop\]" | Select-Object -Last 14 | ForEach-Object Line

$new = Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | Where-Object { $crashBefore -notcontains $_.Name }
foreach ($c in $new) {
  "--- CRASH $($c.Name)"
  $x = Get-Content (Join-Path $c.FullName "CrashContext.runtime-xml") -Raw
  [regex]::Match($x, '<ErrorMessage>(.*?)</ErrorMessage>').Groups[1].Value
  [regex]::Match($x, '<BaseDir>(.*?)</BaseDir>').Groups[1].Value
}
foreach ($p in (Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue)) {
  $tag = if ($p.Path -like "*Trepang2_B*") { "B" } else { "A" }
  if ($p.Responding) { & "$D\shot.ps1" -ProcId $p.Id -Out "$shots\camp$tag.png" | Out-Null; "$tag ok" } else { "$tag NOT RESPONDING" }
}
