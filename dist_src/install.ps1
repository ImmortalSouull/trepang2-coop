# Trepang2 Co-op installer.
# Finds Trepang2 through Steam, installs UE4SS + the T2Coop mod and the network setting.
# Run via install.bat (or: powershell -ExecutionPolicy Bypass -File install.ps1).
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Trepang2 {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += $m.Groups[1].Value -replace '\\\\', '\'
            }
        }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $p = Join-Path $l "steamapps\common\Trepang2"
        if (Test-Path (Join-Path $p "CPPFPS\Binaries\Win64\CPPFPS-Win64-Shipping.exe")) { return $p }
    }
    return $null
}

Write-Host "=== Trepang2 Co-op ===" -ForegroundColor Cyan
$game = Find-Trepang2
if (-not $game) {
    $game = Read-Host "Trepang2 not found automatically. Paste the game folder (the one with CPPFPS.exe)"
}
$win64 = Join-Path $game "CPPFPS\Binaries\Win64"
if (-not (Test-Path (Join-Path $win64 "CPPFPS-Win64-Shipping.exe"))) { throw "Wrong folder: $game" }
Write-Host "Game: $game"

if (Get-Process CPPFPS-Win64-Shipping -ErrorAction SilentlyContinue) { throw "Close Trepang2 first." }

# 1) UE4SS (mod loader). Keep an existing install, but make sure our settings are in place.
Copy-Item (Join-Path $here "files\dwmapi.dll") $win64 -Force
$ue = Join-Path $win64 "ue4ss"
if (-not (Test-Path (Join-Path $ue "UE4SS.dll"))) {
    Copy-Item (Join-Path $here "files\ue4ss") $win64 -Recurse -Force
} else {
    Copy-Item (Join-Path $here "files\ue4ss\UE4SS.dll") $ue -Force
}
$ini = Join-Path $ue "UE4SS-settings.ini"
if (Test-Path $ini) {
    (Get-Content $ini) -replace '^DefaultExecuteInGameThreadMethod\s*=.*', 'DefaultExecuteInGameThreadMethod = ProcessEvent' |
        Set-Content $ini -Encoding ascii
}

# 2) The mod itself.
$mods = Join-Path $ue "Mods"
$dst = Join-Path $mods "T2Coop"
$keepConfig = $null
if (Test-Path (Join-Path $dst "config.txt")) { $keepConfig = Get-Content (Join-Path $dst "config.txt") -Raw }
New-Item -ItemType Directory -Force (Join-Path $dst "Scripts") | Out-Null
Copy-Item (Join-Path $here "files\Mods\T2Coop\Scripts\*") (Join-Path $dst "Scripts") -Force
Copy-Item (Join-Path $here "files\Mods\T2Coop\t2coop_steam.dll") $dst -Force
Copy-Item (Join-Path $here "files\Mods\T2Coop\fixini.ps1") $dst -Force
if ($keepConfig) { Set-Content (Join-Path $dst "config.txt") $keepConfig -NoNewline }

$modsTxt = Join-Path $mods "mods.txt"
$lines = @(Get-Content $modsTxt)
if (-not ($lines -match '^T2Coop\s*:')) {
    $i = [array]::IndexOf($lines, ($lines | Where-Object { $_ -like '; Built-in keybinds*' } | Select-Object -First 1))
    if ($i -lt 0) { $lines += "T2Coop : 1" } else { $lines = @($lines[0..($i - 1)]) + "T2Coop : 1" + @($lines[$i..($lines.Count - 1)]) }
} else {
    $lines = $lines -replace '^T2Coop\s*:.*', 'T2Coop : 1'
}
# UE4SS's stock cheat-manager mod hooks the same engine call the co-op uses and crashed the game
$lines = $lines -replace '^CheatManagerEnablerMod\s*:.*', 'CheatManagerEnablerMod : 0'
Set-Content $modsTxt $lines -Encoding ascii

# 3) Network setting the game needs to host (read by the game at startup).
$cfgDir = Join-Path $env:LOCALAPPDATA "CPPFPS\Saved\Config\WindowsNoEditor"
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$engine = Join-Path $cfgDir "Engine.ini"
$text = if (Test-Path $engine) { Get-Content $engine -Raw } else { "" }
# (not in Steam mode: there the game's own Steam subsystem is used; the mod handles it)
$steamMode = $keepConfig -and ($keepConfig -match '(?m)^\s*net\s*=\s*steam')
if (-not $steamMode -and $text -notmatch '\[OnlineSubsystem\][^\[]*DefaultPlatformService\s*=\s*Null') {
    if (Test-Path $engine) { Copy-Item $engine "$engine.bak_before_coop" -Force }
    # drop a stray Null line from another section, then add the right one
    $text = $text -replace '(?m)^DefaultPlatformService\s*=\s*Null\s*\r?\n?', ''
    Set-Content $engine ($text + "`r`n[OnlineSubsystem]`r`nDefaultPlatformService=Null`r`n") -Encoding ascii -NoNewline
}

# 4) Optional: the host's IP (pre-filled in the F4 menu's join box).
$cfg = Join-Path $dst "config.txt"
if (-not (Test-Path $cfg)) {
    $ip = Read-Host "Host IP for joining (press Enter to skip - you can edit $cfg later)"
    if (-not $ip) { $ip = "127.0.0.1" }
    Set-Content $cfg "join_ip=$ip`r`nmap=/Game/Maps/HordeMode/Horde_Killhouse`r`n" -Encoding ascii
}

Write-Host ""
Write-Host "Installed. In game press F4 for the co-op menu (host / join / leave / arena / network mode)." -ForegroundColor Green
Write-Host "IP mode: the host opens UDP port 7777 (router) or both use Porthole / Radmin VPN."
Write-Host "Steam mode (experimental, switch it in the F4 menu): join by the host's SteamID64, no port forwarding."
