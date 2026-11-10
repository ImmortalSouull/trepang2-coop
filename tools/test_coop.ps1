# Full co-op smoke test: deploy, restart both copies, host on A, join from B,
# then print T2Coop logs, client crash info and save screenshots.
param([string]$Map = "/Game/Maps/HordeMode/Horde_Killhouse", [int]$Settle = 25, [switch]$NoRestart)
$D = $PSScriptRoot
$shots = "C:\Users\PC\AppData\Local\Temp\claude\e7012a5ed48349a9\67fda917-5548-48c7-8c3d-8f6f17551ca2\scratchpad"
$crashDir = "$env:LOCALAPPDATA\CPPFPS\Saved\Crashes"
$crashBefore = @(Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)

& "$D\deploy.ps1" | Out-Null
if (-not $NoRestart) { & "$D\launch.ps1" -Which A,B -Kill | Out-Null; Start-Sleep 5 }

& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd "T2C.devGod=true; T2C.host('$Map'); return 'host'" -Wait 40 | Out-Null
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd 'T2C.stopLoadingScreen(); return "ok"' -Wait 2 | Out-Null
$listen = netstat -ano -p UDP | Select-String ":7777"
"listen: " + [bool]$listen
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'T2C.join("127.0.0.1"); return "join"' -Wait $Settle | Out-Null
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd 'T2C.stopLoadingScreen(); return "ok"' -Wait 3 | Out-Null

$q = 'local s=""; for _,pc in ipairs(FindAllOf("PlayerController") or {}) do local p=pc.Pawn; s=s.." | "..pc:GetFName():ToString().." local="..tostring(pc:IsLocalController()).." role="..tostring(pc.Role); if p:IsValid() then local l=p:K2_GetActorLocation(); s=s..string.format(" %s @ %.0f %.0f %.0f", p:GetFName():ToString(), l.X,l.Y,l.Z) else s=s.." nopawn" end end; return s'
"--- A"
& "$D\t2.ps1" -Inst A -Mod T2Coop -Cmd $q -Wait 2 | Out-Null
Select-String "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log" -Pattern "\[T2Coop\]" | Select-Object -Last 12 | ForEach-Object Line
"--- B"
& "$D\t2.ps1" -Inst B -Mod T2Coop -Cmd $q -Wait 2 | Out-Null
Select-String "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64\ue4ss\UE4SS.log" -Pattern "\[T2Coop\]" | Select-Object -Last 12 | ForEach-Object Line

$new = Get-ChildItem $crashDir -Directory -ErrorAction SilentlyContinue | Where-Object { $crashBefore -notcontains $_.Name }
foreach ($c in $new) {
  "--- CRASH $($c.Name)"
  $x = Get-Content (Join-Path $c.FullName "CrashContext.runtime-xml") -Raw
  [regex]::Match($x, '<ErrorMessage>(.*?)</ErrorMessage>').Groups[1].Value
  [regex]::Match($x, '<BaseDir>(.*?)</BaseDir>').Groups[1].Value
  ([regex]::Match($x, '<PCallStack>([\s\S]*?)</PCallStack>').Groups[1].Value.Split("`n") | Select-Object -First 8) -join "`n"
}
$ids = Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue | Sort-Object StartTime
$i = 0
foreach ($p in $ids) {
  $tag = if ($p.Path -like "*Trepang2_B*") { "B" } else { "A" }
  if ($p.Responding) { & "$D\shot.ps1" -ProcId $p.Id -Out "$shots\shot$tag.png" | Out-Null; "$tag ok" } else { "$tag NOT RESPONDING" }
}
"processes: $($ids.Count)"
