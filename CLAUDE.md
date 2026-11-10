# Trepang2 Co-op mod — project guide for Claude

Talk to the user in Russian. The user plays with a friend; previous project: ZERO Sievert co-op
(`C:\Users\PC\zerosievert-coop`). The user works through Claude only — do the work, test it yourself.

## Read first
- `MODLOG.md` — every engine fact, gotcha and decision so far. Read before changing code.
- `PLAN.md` — stages and what's done.

## Layout
- `mod/T2Coop/Scripts/main.lua` — the co-op mod (UE4SS Lua). Version in `local VERSION`.
- `mod/T2Dev/Scripts/main.lua` — dev remote only (command file → console/Lua). Never shipped.
- `tools/` — `test_coop.ps1` (full 2-instance test), `launch.ps1`, `t2.ps1` (send commands),
  `shot.ps1` (window screenshot), `key.ps1` (send keys), `deploy.ps1` (copies mods to both copies,
  refuses Lua with syntax errors), `build_dist.ps1` (player zip), `luacheck.py`, `natives.py`/`disasm.py`/`xref.py`
  (crash/exe analysis).
- `dist_src/` — installer + README for players. `third_party/` — clean UE4SS release zip.
- `research/CXXHeaderDump/` — UE4SS SDK dump of the game (class/field/function names and offsets).

## Test loop
1. Edit `mod/...`, then `tools/test_coop.ps1` (deploys, restarts game copy A = host and B = client,
   hosts Horde_Killhouse on A, joins from B, prints logs/crashes, saves screenshots to the scratchpad).
2. Poke the running games: `t2.ps1 -Inst A|B -Mod T2Coop -Cmd 'return T2C.where()'`.
   T2Coop exposes its table as `T2C` (host/join/leave/where/walk/notify/allOf/every...).
3. Game copy B (`C:\Users\PC\Trepang2_B`) shares Content/Engine with the real install via junctions.

## Hard rules learned the hard way
- Never call engine functions from inside a hook callback; hooks only queue, the scheduler acts.
- Never call `Die()` from Lua and never hook `BaseCharacter:Die` — UE4SS stops running both mods.
- Periodic work runs from the `PlayerControllerBP_C:ReceiveTick` heartbeat (`S.every`), not
  LoopAsync/LoopInGameThreadWithDelay (those died on the host).
- Hosting needs `[OnlineSubsystem] DefaultPlatformService=Null` in the user Engine.ini.
- Keyboard input can't be faked into an unfocused window for UE4SS keybinds; the mod also polls
  keys via `PlayerController:IsInputKeyDown`, which PostMessage does reach.
- Ask the user before publishing anything (GitHub/Nexus).

## Releases (user's standing order)
- Publish EVERY version to GitHub: `ImmortalSouull/trepang2-coop`, tag `vX.Y.Z`, release notes in
  `docs/releases/vX.Y.Z.md`, asset = `dist/Trepang2-Coop-vX.Y.Z.zip` from `tools/build_dist.ps1`.
  Bump `local VERSION` in main.lua and the version in README.md first.
- Near v1.0.0 (once it's more playable) make a showcase video, like the ZERO Sievert mod had.
