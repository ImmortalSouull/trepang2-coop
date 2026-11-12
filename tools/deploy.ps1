# Copy the project's mods into both game copies and enable them in mods.txt.
$proj = Split-Path $PSScriptRoot -Parent
$targets = @(
  "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64\ue4ss\Mods",
  "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64\ue4ss\Mods",
  "C:\Users\PC\Trepang2_C\CPPFPS\Binaries\Win64\ue4ss\Mods"
)
$mods = Get-ChildItem "$proj\mod" -Directory | ForEach-Object Name
# Refuse to deploy Lua that doesn't compile (saves a full game restart per typo).
$luaFiles = Get-ChildItem "$proj\mod" -Recurse -Filter *.lua | ForEach-Object FullName
& python -I "$PSScriptRoot\luacheck.py" @luaFiles
if ($LASTEXITCODE -ne 0) { throw "Lua syntax error - not deployed" }
foreach ($t in $targets) {
  foreach ($m in $mods) {
    New-Item -ItemType Directory -Force "$t\$m\Scripts" | Out-Null
    Copy-Item "$proj\mod\$m\Scripts\*" "$t\$m\Scripts\" -Recurse -Force
    # native helpers (locked while that game copy runs)
    Get-ChildItem "$proj\mod\$m\*" -Include *.dll,*.ps1 | ForEach-Object {
      try { Copy-Item $_.FullName "$t\$m\" -Force -ErrorAction Stop } catch { "warning: $($_.Exception.Message)" }
    }
  }
  $txt = Get-Content "$t\mods.txt"
  foreach ($m in $mods) {
    if (-not ($txt -match "^$m\s*:")) {
      $i = [array]::IndexOf($txt, ($txt | Where-Object { $_ -like '; Built-in keybinds*' } | Select-Object -First 1))
      $txt = @($txt[0..($i - 1)]) + "$m : 1" + @($txt[$i..($txt.Count - 1)])
    }
  }
  # UE4SS's stock CheatManagerEnabler hooks ClientRestart; with it the game crashed on map loads
  # and on the client's pawn swap (MODLOG 32)
  $txt = $txt -replace '^CheatManagerEnablerMod\s*:.*', 'CheatManagerEnablerMod : 0'
  Set-Content "$t\mods.txt" $txt -Encoding ascii
}
"deployed: $($mods -join ', ')"
