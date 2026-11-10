# Stability: with A hosting and B joined (run test_campaign.ps1 -Travel none first), make the
# GAME reload the level N times (restart or load last save) and report crashes / reconnects.
param([int]$Count = 5, [string]$Kind = "restart")
$D = $PSScriptRoot
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$stop = 'pcall(T2C.stopLoadingScreen)'
$lua = if ($Kind -eq "save") { 'T2C.loadLastSave(); return "travel"' } elseif ($Kind -eq "host") { 'T2C.host(T2C.hostMap); return "travel"' } else {
  'local L=StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C"); local w=FindFirstOf("PlayerController"):GetWorld(); L["Trepang Restart Level"](L, w, w); return "travel"' }
for ($i = 1; $i -le $Count; $i++) {
  $before = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $lua -Wait 35 | Out-Null
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "$stop; return 'ok'" -Wait 1 | Out-Null
  & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd "$stop; return 'ok'" -Wait 25 | Out-Null
  $b = & "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'return "B: "..T2C.where()' -Wait 2 -Grep "cmd ok"
  $new = Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Name }
  $alive = (Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue | Measure-Object).Count
  "#$i processes=$alive crashes=$(@($new).Count) $b"
  if ($alive -lt 2) { break }
}
