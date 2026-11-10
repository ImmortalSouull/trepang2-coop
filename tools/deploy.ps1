# Copy the project's mods into both game copies and enable them in mods.txt.
$proj = Split-Path $PSScriptRoot -Parent
$targets = @(
  "C:\Program Files (x86)\Steam\steamapps\common\Trepang2\CPPFPS\Binaries\Win64\ue4ss\Mods",
  "C:\Users\PC\Trepang2_B\CPPFPS\Binaries\Win64\ue4ss\Mods"
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
  }
  $txt = Get-Content "$t\mods.txt"
  foreach ($m in $mods) {
    if (-not ($txt -match "^$m\s*:")) {
      $i = [array]::IndexOf($txt, ($txt | Where-Object { $_ -like '; Built-in keybinds*' } | Select-Object -First 1))
      $txt = @($txt[0..($i - 1)]) + "$m : 1" + @($txt[$i..($txt.Count - 1)])
    }
  }
  Set-Content "$t\mods.txt" $txt -Encoding ascii
}
"deployed: $($mods -join ', ')"
