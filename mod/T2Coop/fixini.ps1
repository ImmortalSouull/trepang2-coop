# Trepang2 Co-op: the game writes Engine.ini back from memory when it exits, which undid our network
# mode change. The mod starts this script; it waits for the game to close, then sets the mode.
param([string]$Mode, [string]$Ini)
while (Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue) { Start-Sleep 2 }
Start-Sleep 1
$t = [IO.File]::ReadAllText($Ini)
$t = [regex]::Replace($t, '(?m)^DefaultPlatformService\s*=\s*Null[^\n]*\n?', '')
if ($Mode -eq 'ip') { $t = $t.TrimEnd() + "`r`n[OnlineSubsystem]`r`nDefaultPlatformService=Null`r`n" }
[IO.File]::WriteAllText($Ini, $t)
