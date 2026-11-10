# Nexus Mods page — Trepang2 Co-op

## Name
Trepang2 Co-op (Horde Mode) - Beta

## Version
0.6.0

## Category
Gameplay  (tags: Multiplayer / Co-op, Gameplay)

## Short summary (Nexus "Brief overview", max ~350 characters)
Play Trepang2 together. Adds co-op to Horde (Survival) mode: host an arena, a friend joins by IP, fight
the waves side by side with shared money, partner markers and down & revive. Early beta - the full story
campaign in co-op is the goal for v1.0.

## Description (paste into the Nexus description editor, BBCode)

[size=5][b]Trepang2 Co-op[/b][/size]
[i]Unofficial mod. Early beta: Horde mode now, the full story campaign in co-op is the goal for v1.0.[/i]

Trepang2 is a single-player game. This mod turns on Unreal Engine's built-in networking and adds
everything the game is missing for two (or more) players to fight the [b]Horde / Survival[/b] waves together.

[size=4][b]Features[/b][/size]
[list]
[*]In-game co-op menu (F4): host any Horde arena, type the friend's address and join, leave, player list
[*]Player names (Steam) over partner markers, "joined" / "left" notices
[*]Every player plays their own full character: first-person guns, HUD, slow-mo, abilities
[*]Enemies, waves and money run on the host; shots, headshots, damage and deaths are synced
[*]Enemies attack every player
[*]Partner bullets, shotgun pellets, headshots, grenades, kicks (jump kick, dropkick), melee strikes and sword hurt enemies on the host
[*]Partner kills earn Horde money; guns dropped by enemies or bought by the host can be picked up by anyone
[*]Horde HUD (wave, enemies left, money, timer) for everybody
[*][b]Down instead of death[/b]: drop below 30% HP and you go down - a partner standing next to you revives you in 3 s.
If everyone is down, the arena restarts and everyone reconnects automatically
[*]Partner markers with distance, on-screen co-op notices
[*]Tested with 3 players
[/list]

[size=4][b]Installation (every player)[/b][/size]
[list=1]
[*]Close the game.
[*]Unpack the archive anywhere and run [b]install.bat[/b] - it finds Trepang2 through Steam and installs
the UE4SS mod loader (included) and the mod.
[*]Start the game once. If the mod shows "restart the game once" - restart it.
[/list]

[size=4][b]Playing over the internet[/b][/size]
The host needs [b]UDP port 7777[/b] open on the router, or both players use a virtual LAN such as
Porthole, Radmin VPN or ZeroTier. The friend types the host's IP in the F4 menu and clicks Join.
[b]Steam mode (experimental)[/b]: no port forwarding - both switch it in the F4 menu and restart the game. The host presses [b]Invite (Steam)[/b] in the F4 menu and picks the friend in the Steam overlay; the friend accepts and joins automatically (or uses "Join game" in the Steam friends list, or types the host's SteamID64).

[size=4][b]Known issues (beta)[/b][/size]
[list]
[*]Fire / incendiary damage from the partner is not synced yet
[*]Ammo / health pickups are separate for each player
[*]Steam mode is not yet tested between two different Steam accounts
[*]Campaign co-op is early (v0.6): host presses F4 - HOST in the safehouse or a mission, friends follow the host through levels and checkpoints; cutscenes not synced yet
[*]While installed, the game's online subsystem is set to "Null" (needed to host). To undo: delete the
[OnlineSubsystem] section from %LOCALAPPDATA%\CPPFPS\Saved\Config\WindowsNoEditor\Engine.ini
[/list]

[size=4][b]Roadmap[/b][/size]
[list]
[*][b]v0.6[/b] - campaign basics: missions together, level transitions, safehouse lobby, checkpoints
[*][b]v0.7[/b] - campaign scripts: doors, elevators, objectives, cutscenes and dialogue for everyone, terminals and hostages
[*][b]v0.8[/b] - bosses, special levels, side missions, difficulty for more players
[*][b]v0.9[/b] - progression for every player, spectating, rejoining, full-campaign testing
[*][b]v1.0[/b] - the whole Trepang2 campaign + Horde playable in co-op
[/list]

[size=4][b]Uninstall[/b][/size]
Delete [i]dwmapi.dll[/i] and the [i]ue4ss[/i] folder from [i]Trepang2\CPPFPS\Binaries\Win64[/i].

[size=4][b]Credits[/b][/size]
[list]
[*]UE4SS (RE-UE4SS team, MIT license) - the mod loader bundled with this mod
[*]Source code and release notes: github.com/ImmortalSouull/trepang2-coop
[/list]
[i]This mod was made with the help of AI (Claude). It is not affiliated with Trepang Studios or Team17.
No game files are included.[/i]

## Files to upload
- Main file: dist/Trepang2-Coop-v0.6.0.zip  (name: "Trepang2 Co-op v0.6.0 (beta)")
- Requirements to declare on Nexus: none extra (UE4SS is bundled)
