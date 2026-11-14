# Nexus Mods page — Trepang2 Co-op

## Name
Trepang2 Co-op (Horde + Campaign)

## Version
1.0.0

## Category
Gameplay  (tags: Multiplayer / Co-op, Gameplay)

## Short summary (Nexus "Brief overview", max ~350 characters)
Play Trepang2 together: co-op Horde and the story campaign. Friends follow the host through missions, checkpoints and cutscenes (which wait for everyone). Your safehouse look is shared, partners are fully animated. Join by IP or Steam invite. v1.0: the whole campaign in co-op.

## Description (paste into the Nexus description editor, BBCode)

[size=5][b]Trepang2 Co-op[/b][/size]
[i]Unofficial mod. Version 1.0: Horde and the whole story campaign are playable together - every map, arena and side mission has been played in co-op. Showcase video on the page.[/i]

Trepang2 is a single-player game. This mod switches on Unreal Engine's own networking and adds everything the game is missing for up to 4 players: [b]Horde / Survival[/b] together and the [b]story campaign[/b] together.

[size=4][b]Campaign co-op[/b][/size]
[list]
[*]Play the campaign as usual. In the safehouse or in a mission the host opens the co-op menu ([b]F4[/b]) and presses [b]HOST[/b] - the level reloads from the last checkpoint with the server on - and friends join.
[*][b]The host leads the group[/b]: picking a mission at the safehouse map, the helicopter ride, the next level, loading a checkpoint, restarting - wherever the host goes, friends follow automatically.
[*][b]Cutscenes for everyone[/b]: a cutscene waits until every player has come to where it starts ("WAITING FOR PLAYERS 1/2" at the top of the screen and a "GATHER HERE" marker), then plays for all players at the same moment. Partners are not written into the scene; afterwards everyone continues together.
[*][b]Radio and dialogue[/b] lines with the speaker's portrait and subtitles are heard by all.
[*][b]Story events are shared[/b]: objectives, doors, scripted triggers - a friend walking into a trigger sets it off for everyone. Doors the story locks or unlocks match on every machine.
[*][b]Level pieces move for everyone[/b]: elevators (a partner riding one goes along), elevator doors, roll-up doors, laser gates and collapsing walls change on every machine.
[*][b]Fell off the map?[/b] You're brought back to the host automatically.
[*][b]Interactions are shared[/b]: terminals, buttons, levers, elevators and scripted scenes (like forcing the cultists' heavy doors) - whoever presses F, the story moves for everyone, and things the story switches on or off match for all players.
[*][b]Objective markers[/b] the story shows ("find the Enforcer", distance through walls) appear for every player.
[*][b]Side missions[/b] work the same way: start one, F4 - HOST, friends join.
[*][b]Mission loadout[/b]: a friend joining a mission finds the host's mission weapon at their feet (hold F); the gas mask (KillGhosts) goes on and off for everyone together.
[*]Enemy squads come from the host and are the same for everybody.
[*][b]Boss health bars[/b] show for every player, not just the host.
[*][b]Tougher enemies for more players[/b]: +50% health for every extra player (campaign and Horde). The host picks it in the F4 menu - ENEMY HEALTH: from +0% to +200% per extra player.
[*]Checkpoints are saved by the host only - friends' own campaign saves are left alone. [b]Progress counts for friends too[/b]: missions finished, HVTs killed, weapon customizations and dual wield are added to every player's own unlocks. Crashed? Restart the game and join again - you're put back next to the host. When the level moves the host far away (the Backrooms, scene cuts), friends are brought along.
[*][b]Down & revive[/b]: drop below 30% HP and you go down; a partner standing next to you revives you. While down you watch through your partner's eyes (left click switches to your own view). If everyone is down, the group goes back to the last checkpoint.
[/list]

[size=4][b]Horde co-op[/b][/size]
[list]
[*]Host any Horde arena from the F4 menu (also custom community Horde maps: load the map, press HOST).
[*]Enemies, waves and money run on the host; the Horde HUD (wave, enemies left, money, timer) for everyone.
[*]Partner bullets, shotgun pellets, headshots, grenades, kicks, dropkicks, melee strikes and sword hurt enemies; partner kills earn Horde money.
[*]Guns dropped by enemies or bought by the host can be picked up by anyone.
[*][b]The shop works for partners[/b]: they see the shared money and buy for themselves (the item lands right behind them); squads they buy join the fight for everyone.
[*][b]Human shields[/b]: a partner can grab an enemy, hold it, let it go or throw it - the real enemy follows, everyone sees it.
[*][b]Fire[/b]: a partner's incendiary rounds and molotovs set the real enemies on fire; burning enemies burn on every screen.
[*]Down & revive; if everyone is down the arena restarts and everyone reconnects automatically.
[/list]

[size=4][b]Players[/b][/size]
[list]
[*][b]Your look is shared[/b]: every player appears exactly as they dressed in the safehouse - the game's own outfits (106, Patriarch, 107 and the others you unlocked) and the customization (jacket, gloves, pants, shoes, colours and camo). Change it at the safehouse station like in single player. Or [b]dress up as an enemy[/b]: in the F4 menu pick any of 300 enemy variants from about 30 factions (Mall Cops, Cultists, Horizon guards / elite / TTMF with night vision / Black Ops, Bad Oil bandits, Lawyer Thugs, Replicas, 107 and more) - with a turning preview of how the others will see you. Real enemy gear, everyone sees it.
[*][b]Fully animated partners[/b]: walking, sprinting, crouching, sliding, jumping, dropkick, aiming up and down, the right grip for every weapon, dual wielding - and reloading, weapon melee strikes (also on enemies on the ground), grenade throws and weapon switches.
[*]Partners' and the host's shots are seen and heard by everyone (gun animation, sound, muzzle flash). Flashlights too: in a dark level you see your partner's beam.
[*][b]Slow-mo for everyone[/b]: when the host or a partner uses slow-mo (Q), time slows down for all players together (a partner's lasts 5 s, Q again ends it).
[*][b]Invisibility (E) works in co-op[/b]: an invisible partner disappears for everyone (body, enemy look and gun) and the enemies stop seeing them.
[*]Steam names over partner markers (with distance, visible through walls) with their health ("Name 60%", "Name - DOWN"), "joined" / "left" notices.
[*]Up to 4 players - every feature tested with 1, 2, 3 and 4 players.
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
[*][b]F4[/b] - the co-op menu in three short tabs. [b]CO-OP[/b]: host, join, leave, Horde arena, players with their health and ping, TO THE HOST (stuck somewhere? it puts you next to the host), network mode, Steam invite. [b]LOOK[/b]: how the others see you. [b]EXTRAS[/b]: enemy health and optional tweaks just for you - health regen up to 50/75/100%, max armor 100/200/300, auto resupply (ammo, a grenade and focus every 60 or 30 s), resupply on every kill, heal on execution, keep your weapon mods on guns you pick up, remember your cheats between launches, randomizer (random weapon mods and colours). Everything is off by default.
[*][b]F6[/b] - quick access: weapon mods anywhere; in the safehouse missions, outfit, combat simulator and cheats; in Horde the shop. No more running around.
[*][b]X[/b] (gamepad: d-pad left) - ping: a marker with your name where you look, for everyone, 8 seconds. On an enemy it sticks to them and says ENEMY.
[/list]

[size=4][b]Known issues[/b][/size]
[list]
[*]Boss fights are shared like every other enemy, but their scripted scenes have not been played start to finish in co-op yet - please report how they go.
[*]Checked in co-op: every campaign map (join, level restarts, checkpoint reloads), the Safehouse betrayal, the credits and the end of the game, side missions, all Horde arenas.
[*]A partner's gun shows without its attachments and skin on the others' screens.
[*]After a level change friends reconnect on their own a few seconds after the host's level is up (about 15 seconds on a restart).
[*]Dual wielding shows both guns but with a two-handed pose.
[*]Ammo and health pickups are separate for each player.
[*]Steam mode is not yet tested between two different Steam accounts (one report of the joining player stuck on the title screen - use IP mode with Radmin VPN / ZeroTier meanwhile, and please send the joiner's UE4SS.log); players on a non-Steam copy can only use IP mode.
[*]While installed, the game's online subsystem is set to "Null" (needed to host). To undo: delete the [OnlineSubsystem] section from %LOCALAPPDATA%\CPPFPS\Saved\Config\WindowsNoEditor\Engine.ini
[/list]

[size=4][b]Roadmap[/b][/size]
[list]
[*][b]v0.7.4[/b] - done: interactions (terminals, buttons, scenes), objective markers, human shields, partner fire
[*][b]v0.8.0-0.8.4[/b] - done: boss health bars for all, enemy health setting in the menu, side missions, mission weapon and gas mask for friends
[*][b]v0.8.x[/b] - bosses' special mechanics, special levels, side missions
[*][b]v0.9[/b] - done: spectating while down, progress for every player, rejoining, elevators and level pieces, end of the game
[*][b]v1.0[/b] - done: the whole Trepang2 campaign + Horde playable in co-op
[*][b]next[/b] - co-op for up to 4 players
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
