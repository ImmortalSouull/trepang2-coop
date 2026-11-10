# Hold keys in game copy B (the guest) and record what its own legs anim instance (MeshLegs,
# ABP_TPP_Player) and pawn report meanwhile. Prints a few samples.
# Usage: anim_probe.ps1 -Vks 0x57,0xA0 [-HoldMs 1500] [-Label sprint]
param([int[]]$Vks = @(), [int]$HoldMs = 1500, [string]$Label = "probe", [switch]$Click, [switch]$RClick, [string]$Inst = "B")
$D = $PSScriptRoot
$lua = @'
local p = T2C.client and T2C.client.pawn
if not (p and p:IsValid()) then local pc; for _,c in ipairs(FindAllOf("PlayerController")) do if c:IsLocalController() then pc=c end end; p = pc.Pawn end
local n = 0
T2C.probe = {}
T2C.every(150, function()
  n = n + 1
  local ai = p.MeshLegs.AnimScriptInstance
  local w = p.CurrentWeapon
  local s = string.format("spd=%.0f dir=%.0f mov=%s cr=%s sl=%s jmp=%s gnd=%s stance=%s kick=%s low=%s melee=%s at=%s cw=%s lean=%s",
    ai.Speed, ai.Direction, tostring(ai.Moving), tostring(ai.Crouching), tostring(ai.IsSliding), tostring(ai.Jumping),
    tostring(ai.IsOnGround), tostring(ai.Stance), tostring(ai.IsKicking), tostring(ai.IsWeaponLowered),
    tostring(ai.bIsMeleeMode), tostring(ai.AnimType), tostring(ai.CurrentWeapon), tostring(ai.LeanStatus))
  pcall(function() s = s .. string.format(" zoom=%.2f", p.ZoomAlpha) end)
  pcall(function() s = s .. " sprint=" .. tostring(p:GetIsSprinting()) end)
  pcall(function() s = s .. " dual=" .. tostring(w:GetIsDualWielding()) .. " rel=" .. tostring(w:GetIsReloading()) end)
  pcall(function() local v = p:GetVelocity(); s = s .. string.format(" v=%.0f", math.sqrt(v.X*v.X+v.Y*v.Y)) end)
  table.insert(T2C.probe, s)
  if n >= 16 then
    for i, l in ipairs(T2C.probe) do if i % 3 == 1 then print("[T2Coop] PROBE " .. l .. "\n") end end
    return true
  end
end)
return "probe"
'@ -replace "`r?`n", " "
& "$D\t2.ps1" -Inst $Inst -Mod T2Coop -Cmd $lua -Wait 0 | Out-Null
$p = Get-Process CPPFPS-Win64-Shipping | Where-Object { ($Inst -eq "B") -eq ($_.Path -like "*Trepang2_B*") } | Select-Object -First 1
Start-Sleep -Milliseconds 300
if ($Click) { & "$D\key.ps1" -ProcId $p.Id -Click -HoldMs $HoldMs -Focus | Out-Null }
elseif ($RClick) { & "$D\key.ps1" -ProcId $p.Id -RClick -HoldMs $HoldMs -Focus | Out-Null }
elseif ($Vks.Count) { & "$D\key.ps1" -ProcId $p.Id -Vks $Vks -HoldMs $HoldMs -Focus | Out-Null }
Start-Sleep 3
"== $Label"
$roots = @{ A = "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64"; B = "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64" }
Select-String "$($roots[$Inst])\ue4ss\UE4SS.log" -Pattern "PROBE" | Select-Object -Last 6 | ForEach-Object { $_.Line -replace '^.*PROBE ', '' }
