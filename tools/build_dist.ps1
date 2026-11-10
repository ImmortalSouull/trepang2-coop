# Build the player package: dist/Trepang2-Coop-v<version>.zip
# Contents: install.bat/.ps1, README, clean UE4SS (from third_party zip) and the T2Coop mod (no dev tools).
# Staging happens in %TEMP% because the project path can be too long for UE4SS's nested folders.
$proj = Split-Path $PSScriptRoot -Parent
$lua = Get-Content "$proj\mod\T2Coop\Scripts\main.lua" -Raw
$ver = [regex]::Match($lua, 'local VERSION = "([^"]+)"').Groups[1].Value
& python -I "$PSScriptRoot\luacheck.py" "$proj\mod\T2Coop\Scripts\main.lua"
if ($LASTEXITCODE -ne 0) { throw "Lua syntax error" }

$name = "Trepang2-Coop-v$ver"
$stage = Join-Path $env:TEMP "t2coop_build\$name"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\files\Mods\T2Coop\Scripts" | Out-Null

Copy-Item "$proj\dist_src\install.bat", "$proj\dist_src\install.ps1", "$proj\dist_src\README.ru.md" $stage
$ue = Get-ChildItem "$proj\third_party" -Filter "UE4SS_*.zip" | Select-Object -First 1
Expand-Archive $ue.FullName "$stage\files" -Force          # -> files\dwmapi.dll, files\ue4ss\...
(Get-Content "$stage\files\ue4ss\UE4SS-settings.ini") -replace '^DefaultExecuteInGameThreadMethod\s*=.*', 'DefaultExecuteInGameThreadMethod = ProcessEvent' |
    Set-Content "$stage\files\ue4ss\UE4SS-settings.ini" -Encoding ascii
(Get-Content "$stage\files\ue4ss\Mods\mods.txt") -replace '^CheatManagerEnablerMod\s*:.*', 'CheatManagerEnablerMod : 0' |
    Set-Content "$stage\files\ue4ss\Mods\mods.txt" -Encoding ascii
Copy-Item "$proj\mod\T2Coop\Scripts\main.lua" "$stage\files\Mods\T2Coop\Scripts\"
& python -I "$PSScriptRoot\build_steamdll.py" | Out-Null
Copy-Item "$proj\mod\T2Coop\t2coop_steam.dll" "$stage\files\Mods\T2Coop\"

New-Item -ItemType Directory -Force "$proj\dist" | Out-Null
$zip = "$proj\dist\$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$stage\*" -DestinationPath $zip
"built $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
