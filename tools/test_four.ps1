# Up-to-4-player test: host on A, partners B, C, D join; every copy reports who it sees.
# -Restarts N: then N level restarts by the host (partners must come back on their own).
# Campaign maps overwrite the campaign save: back it up first (see CLAUDE.md).
param([string]$Map = "/Game/Maps/HordeMode/Horde_Killhouse", [string[]]$Clients = @("B", "C", "D"), [int]$Restarts = 0)
$D = $PSScriptRoot
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$crashBefore = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
& "$D\deploy.ps1" | Out-Null
& "$D\launch.ps1" -Which (@("A") + $Clients) -Kill | Out-Null
Start-Sleep 5
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "T2C.devGod=true; T2C.host('$Map'); return 'host'" -Wait 42 | Out-Null
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'pcall(T2C.stopLoadingScreen); return "ok"' -Wait 2 | Out-Null
foreach ($c in $Clients) {
  & "$D\t2.ps1" -Inst $c -Mod T2Coop -Cmd 'T2C.join("127.0.0.1"); return "join"' -Wait 2 | Out-Null
}
Start-Sleep 30
# who does each copy see: local pawn + every visible player pawn
$q = 'local o={}; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if p:IsValid() and not p.bHidden then local l=p:K2_GetActorLocation(); table.insert(o, string.format("%.0f,%.0f", l.X, l.Y)) end end; local GS=StaticFindObject("/Script/Engine.Default__GameplayStatics"); return "SEE "..#o.." "..GS:GetCurrentLevelName(FindFirstOf("PlayerController"):GetWorld(), true):ToString().." "..table.concat(o," ")'
function Report($tag) {
  foreach ($i in (@("A") + $Clients)) {
    & "$D\t2.ps1" -Inst $i -Mod T2Coop -Cmd 'pcall(T2C.stopLoadingScreen); return "ok"' -Wait 1 | Out-Null
    $r = & "$D\t2.ps1" -Inst $i -Mod T2Coop -Cmd $q -Wait 2 -Grep "cmd ok"
    "$tag $i " + ("$r" -replace '.*cmd ok: ', '')
  }
  $new = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | Where-Object { $crashBefore -notcontains $_.Name })
  "$tag processes=$(@(Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue).Count) crashes=$($new.Count)"
}
Report "join"
for ($n = 1; $n -le $Restarts; $n++) {
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'local L=StaticFindObject("/Game/Blueprint/Game/BP_MissionLib.Default__BP_MissionLib_C"); local w=FindFirstOf("PlayerController"):GetWorld(); L["Trepang Restart Level"](L, w, w); return "travel"' -Wait 40 | Out-Null
  & "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'pcall(T2C.stopLoadingScreen); return "ok"' -Wait 30 | Out-Null
  Report "restart$n"
}
