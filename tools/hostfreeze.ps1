# Freeze check: N host starts in a row with partners joining each time (copies -Players).
# A hung host gets a minidump (C:\Users\PC\trepang2-coop-work\hang_<n>.dmp) and all games restart.
param([int]$Count = 12, [int]$Players = 4, [switch]$NoPress, [string[]]$Maps = @("/Game/Maps/HordeMode/Horde_Killhouse", "/Game/Maps/Campaign/Cultists/KillCultists_Persistent"))
$T = $PSScriptRoot
$all = @("A", "B", "C", "D")[0..($Players - 1)]
$cl = @($all | Where-Object { $_ -ne "A" })
& "$T\deploy.ps1" | Out-Null
$fresh = $true
$hangs = 0
for ($n = 1; $n -le $Count; $n++) {
  if ($fresh) { & "$T\launch.ps1" -Which $all -Kill | Out-Null; Start-Sleep 5; $fresh = $false }
  $m = $Maps[($n - 1) % $Maps.Count]
  & "$T\t2.ps1" -Inst A -Mod T2Coop -Cmd "$(if ($NoPress) {"T2C.off.ls=true; "})T2C.devGod=true; T2C.host('$m'); return 'host'" -Wait 1 | Out-Null
  Start-Sleep 3
  foreach ($c in $cl) { & "$T\t2.ps1" -Inst $c -Mod T2Coop -Cmd 'if not T2C.joined then T2C.join("127.0.0.1") end; return "j"' -Wait 0 | Out-Null }
  Start-Sleep 40
  $hung = @()
  foreach ($p in Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue) {
    if (-not $p.Responding) { Start-Sleep 5; $p.Refresh(); if (-not $p.Responding) { $hung += $p } }
  }
  $r = & "$T\t2.ps1" -Inst A -Mod T2Coop -Cmd 'local n=0; for _,p in ipairs(T2C.allOf("/Script/CPPFPS.BasePlayer")) do if not p.bHidden then n=n+1 end end; return "players "..n' -Wait 3 -Grep "cmd ok"
  $procs = @(Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue).Count
  "#$n $(($m -split '/')[-1]) procs=$procs hung=$($hung.Count) $("$r" -replace '.*cmd ok: ','')"
  if ($hung.Count -gt 0 -or $procs -lt $Players) {
    $hangs++
    foreach ($p in $hung) { & python "$T\minidump.py" $p.Id "C:\Users\PC\trepang2-coop-work\hang_${n}_$($p.Id).dmp" | Out-Null; "  dump hang_${n}_$($p.Id).dmp  $($p.Path)" }
    $fresh = $true
  }
}
"hangs: $hangs of $Count"
