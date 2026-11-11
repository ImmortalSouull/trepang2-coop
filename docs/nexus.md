# Nexus Mods page — Trepang2 Co-op

## Name
Trepang2 Co-op (Horde + Campaign) - Beta

## Version
0.9.0

## Category
Gameplay  (tags: Multiplayer / Co-op, Gameplay)

## Short summary (Nexus "Brief overview", max ~350 characters)
Play Trepang2 together: co-op Horde and the story campaign. Friends follow the host through missions, checkpoints and cutscenes (which wait for everyone). Your safehouse look is shared, partners are fully animated. Join by IP or Steam invite. Beta - the whole campaign is the goal for v1.0.

## Description (paste into the Nexus description editor, BBCode)

[size=5][b]Trepang2 Co-op[/b][/size]
[i]Unofficial mod. Beta: Horde co-op is complete, the story campaign is playable together and getting more complete with every version. Goal for v1.0: the whole campaign in co-op.[/i]

Trepang2 is a single-player game. This mod switches on Unreal Engine's own networking and adds everything the game is missing for two (or more) players: [b]Horde / Survival[/b] together and the [b]story campaign[/b] together.

[size=4][b]Campaign co-op[/b][/size]
[list]
[*]Play the campaign as usual. In the safehouse or in a mission the host opens the co-op menu ([b]F4[/b]) and presses [b]HOST[/b] - the level reloads from the last checkpoint with the server on - and friends join.
[*][b]The host leads the group[/b]: picking a mission at the safehouse map, the helicopter ride, the next level, loading a checkpoint, restarting - wherever the host goes, friends follow automatically.
[*][b]Cutscenes for everyone[/b]: a cutscene waits until every player has come to where it starts ("WAITING FOR PLAYERS 1/2" at the top of the screen and a "GATHER HERE" marker), then plays for all players at the same moment. Partners are not written into the scene; afterwards everyone continues together.
[*][b]Radio and dialogue[/b] lines with the speaker's portrait and subtitles are heard by all.
[*][b]Story events are shared[/b]: objectives, doors, scripted triggers - a friend walking into a trigger sets it off for everyone. Doors the story locks or unlocks match on every machine.
[*][b]Interactions are shared[/b]: terminals, buttons, levers, elevators and scripted scenes (like forcing the cultists' heavy doors) - whoever presses F, the story moves for everyone, and things the story switches on or off match for all players.
[*][b]Objective markers[/b] the story shows ("find the Enforcer", distance through walls) appear for every player.
[*][b]Side missions[/b] work the same way: start one, F4 - HOST, friends join.
[*][b]Mission loadout[/b]: a friend joining a mission finds the host's mission weapon at their feet (hold F); the gas mask (KillGhosts) goes on and off for everyone together.
[*]Enemy squads come from the host and are the same for everybody.
[*][b]Boss health bars[/b] show for every player, not just the host.
[*][b]Tougher enemies for more players[/b]: +50% health for every extra player (campaign and Horde). The host picks it in the F4 menu - ENEMY HEALTH: from +0% to +200% per extra player.
[*]Checkpoints are saved by the host only - friends' own campaign saves are left alone.
[*][b]Down & revive[/b]: drop below 30% HP and you go down; a partner standing next to you revives you. While down you watch through your partner's eyes (left click switches to your own view). If everyone is down, the group goes back to the last checkpoint.
[/list]

[size=4][b]Horde co-op[/b][/size]
[list]
[*]Host any Horde arena from the F4 menu (also custom community Horde maps: load the map, press HOST).
[*]Enemies, waves and money run on the host; the Horde HUD (wave, enemies left, money, timer) for everyone.
[*]Partner bullets, shotgun pellets, headshots, grenades, kicks, dropkicks, melee strikes and sword hurt enemies; partner kills earn Horde money.
[*]Guns dropped by enemies or bought by the host can be picked up by anyone.
[*][b]Human shields[/b]: a partner can grab an enemy, hold it, let it go or throw it - the real enemy follows, everyone sees it.
[*][b]Fire[/b]: a partner's incendiary rounds and molotovs set the real enemies on fire; burning enemies burn on every screen.
[*]Down & revive; if everyone is down the arena restarts and everyone reconnects automatically.
[/list]

[size=4][b]Players[/b][/size]
[list]
[*][b]Your look is shared[/b]: every player appears exactly as they dressed in the safehouse - the game's own outfits (106, Patriarch, 107 and the others you unlocked) and the customization (jacket, gloves, pants, shoes, colours and camo). Change it at the safehouse station like in single player. Or [b]dress up as an enemy[/b]: in the F4 menu pick any of about 330 enemy variants from 30 factions (Mall Cops, Cultists, Horizon guards / elite / TTMF with night vision / Black Ops, Hazmats, Bad Oil bandits, Lawyer Thugs, Replicas, 107 and more) - with a turning preview of how the others will see you. Real enemy gear, everyone sees it.
[*][b]Fully animated partners[/b]: walking, sprinting, crouching, sliding, jumping, dropkick, aiming up and down, the right grip for every weapon, dual wielding - and reloading, weapon melee strikes (also on enemies on the ground), grenade throws and weapon switches.
[*]Partners' and the host's shots are seen and heard by everyone (gun animation, sound, muzzle flash).
[*]Steam names over partner markers (with distance, visible through walls), "joined" / "left" notices.
[*]Tested with 3 players; works with more.
[/list]

[size=4][b]Connecting[/b][/size]
[list]
[*][b]IP mode[/b] (default): the host opens UDP port 7777 on the router, or both players use a virtual LAN (Porthole, Radmin VPN, ZeroTier). The friend types the host's IP in the F4 menu and clicks JOIN.
[*][b]Steam mode[/b] (experimental, no port forwarding): both switch it in the F4 menu and restart the game. The host presses [b]INVITE (STEAM)[/b] and picks the friend in the Steam overlay; the friend accepts and joins automatically (or uses "Join game" in the Steam friends list).
[/list]

[size=4][b]Installation (every player)[/b][/size]
[list=1]
[*]Close the game.
[*]Unpack the archive anywhere (Desktop is fine) and run [b]install.bat[/b] - it finds Trepang2 through Steam and installs the UE4SS mod loader (included) and the mod. You don't copy anything into the game folder yourself.
[*]Start the game once. If the mod says "restart the game once" - restart it.
[*]Press [b]F4[/b] in the game. README.txt in the archive has the full guide.
[/list]

[size=4][b]Controls[/b][/size]
[list]
[*][b]F4[/b] - the co-op menu: host, join, leave, Horde arena, players, network mode, Steam invite, your look, enemy health. Everything is there - no other keys.
[/list]

[size=4][b]Known issues (beta)[/b][/size]
[list]
[*]Campaign: bosses and some special scenes are not synced yet; elevators are shared through their buttons but not tested on every level yet.
[*]Checked in co-op: Prologue, KillCultists, KillSyndicate, KillGhosts, KillMothman, KillHorizon, the Safehouse betrayal, the credits, side missions. In the betrayal scene the partner still sees their HUD.
[*]After a level change friends reconnect in about 30-40 seconds while the level loads.
[*]Dual wielding shows both guns but with a two-handed pose.
[*]Ammo and health pickups are separate for each player.
[*]Steam mode is not yet tested between two different Steam accounts; players on a non-Steam copy can only use IP mode.
[*]While installed, the game's online subsystem is set to "Null" (needed to host). To undo: delete the [OnlineSubsystem] section from %LOCALAPPDATA%\CPPFPS\Saved\Config\WindowsNoEditor\Engine.ini
[/list]

[size=4][b]Roadmap[/b][/size]
[list]
[*][b]v0.7.4[/b] - done: interactions (terminals, buttons, scenes), objective markers, human shields, partner fire
[*][b]v0.8.0-0.8.4[/b] - done: boss health bars for all, enemy health setting in the menu, side missions, mission weapon and gas mask for friends
[*][b]v0.8.x[/b] - bosses' special mechanics, special levels, side missions
[*][b]v0.9[/b] - spectating while down (done in 0.9.0), progression for every player, rejoining, a full campaign run together
[*][b]v1.0[/b] - the whole Trepang2 campaign + Horde playable in co-op
[/list]

[size=4][b]Uninstall[/b][/size]
Delete [i]dwmapi.dll[/i] and the [i]ue4ss[/i] folder from [i]Trepang2\CPPFPS\Binaries\Win64[/i].

[size=4][b]Credits[/b][/size]
[list]
[*]UE4SS (RE-UE4SS team, MIT license) - the mod loader bundled with this mod
[*]Source code, all versions and release notes: github.com/ImmortalSouull/trepang2-coop
[/list]
[i]This mod was made with the help of AI (Claude). It is not affiliated with Trepang Studios or Team17. No game files are included.[/i]

## Files to upload
See nexus_upload/ (one folder per version: zip + changelog.txt) and docs/nexus_upload.md.
