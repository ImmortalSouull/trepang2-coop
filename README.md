# Trepang2 Co-op

**English** · [Русский](dist_src/README.ru.md)

An unofficial mod that adds **co-op** to **Trepang2** — for now in **Horde (Survival)** mode.
Built on Unreal Engine's own networking plus the [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) mod loader.

> The mod was made with AI (Claude) to the player's design. It is not affiliated with Trepang Studios /
> Team17. No game files are stored or distributed here.

**Current version: v0.4.0 (alpha)** — download it from [Releases](../../releases).
Notes for every version are in [docs/releases](docs/releases).

![Host sees the partner](screenshots/host_sees_client.png)

## Install (both players)
1. Close the game, unpack the release zip, run `install.bat` (finds Trepang2 through Steam).
2. Start the game once; if the mod says "restart the game once" — restart it.

## Play
| Key | Action |
|---|---|
| F8 | pick a Horde arena (cycles through ~40) |
| F5 | host co-op on the selected arena |
| F6 | join the host (IP in `ue4ss/Mods/T2Coop/config.txt`) |
| F7 | leave co-op |

Over the internet the host needs **UDP port 7777** open, or both players use Porthole / Radmin VPN / ZeroTier.

## Features
- Each player plays their own full character; enemies, waves and money run on the host.
- Shots, damage (incl. headshots) and enemy deaths synced both ways; enemies hurt both players.
- Horde HUD for the partner; down & revive instead of death; auto-reconnect after an arena restart.
- Partner picks up dropped / bought weapons; partner kills earn Horde money; partner markers; 3+ players.

## Known issues
See [docs/releases](docs/releases). Story missions are not supported yet.

## For developers
`mod/T2Coop/Scripts/main.lua` is the whole mod. `MODLOG.md` documents every engine finding,
`PLAN.md` the roadmap, `tools/` the two-instance test setup.
