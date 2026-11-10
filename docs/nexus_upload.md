# Nexus upload (manual) - v0.7.1

1. Files tab -> Add file: `dist/Trepang2-Coop-v0.7.1.zip`, name "Trepang2 Co-op v0.7.1 (beta)", version 0.7.1,
   category Main files. Older main files -> move to "Old versions" (or Archived). One file is enough:
   every older version stays downloadable on GitHub.
2. Edit mod -> Details: version `0.7.1`; name, short summary and description - copy from `docs/nexus.md`
   (the description is BBCode, paste it as is).
3. Changelogs tab: one entry per version below (version field = the number, text = the lines).

## 0.4.2
- The partner's frag grenades now damage enemies on the host (with falloff from the center), and grenade kills earn Horde money. The partner's game reports where its grenade exploded and the host applies the damage there. Players are not hurt by the partner's grenades.
- Verified with test explosions; please report if a real thrown grenade doesn't count. Known issues: the partner's kick and sword don't damage enemies on the host yet; a "NONE" label when the host aims at a partner; internet play needs UDP port 7777 (or Porthole / Radmin VPN / ZeroTier).

## 0.4.3
- The partner's kicks and sword swings now damage enemies on the host (kick damage and headshot multiplier from the game, sword damage from the weapon), and these kills earn Horde money.
- Verified with test kicks; please report if a real kick or sword swing doesn't count.
- The kick is read from the default Melee key (right mouse button). Known issues: a "NONE" label when the host aims at a partner; internet play needs UDP port 7777 (or Porthole / Radmin VPN / ZeroTier); story missions aren't supported yet.

## 0.4.4
- Fixed the partner melee: the Melee key (right mouse) is a kick in the air and a strike with the weapon (butt / grip / fist) on the ground. Each now uses its own damage, headshot multiplier and range from the game (before, every melee used kick damage).

## 0.4.5
- The partner's two-leg dropkick (sprint + jump + melee) now hurts enemies on the host: every enemy the flying partner crashes into takes 1.5x kick damage (kills a cultist), kills earn money.
- A normal air kick is not counted twice when it turns into a dropkick.
- Verified with a test dropkick hit; please report if a real dropkick does not count.

## 0.5.0
- Co-op menu (F4) in the main menu and in game: Host, Next arena, type the join address + Join, Leave, list of players, network mode switch. The F5–F8 keys still work.
- Player names: Steam names (or name= in config.txt) over the partner markers, in the menu and instead of the "NONE" label when you aim at a partner; "X joined" / "X left" notices.
- Steam mode (experimental): no port forwarding - switch it in the F4 menu (both players, restart the game), the friend joins with the host's SteamID64 shown in the menu. Not yet tested between two different Steam accounts; if it does not connect, switch back to IP mode.
- The host notices a partner who left within 5 seconds (was about a minute).

## 0.5.1
- Steam invites (Steam mode): the host presses INVITE (STEAM) in the F4 menu and picks a friend in the Steam overlay. The friend accepts the invite and joins automatically - if their game was closed, Steam starts it and it connects once the main menu is up.
- "Join game" in the Steam friends list works for a friend who is hosting co-op.
- The F4 menu lists Steam friends who are hosting right now - click a name to join.
- Done by a small native helper (t2coop_steam.dll) that talks to the game's own Steam API.
- Still experimental: accepting an invite could not be tested on a single Steam account. Players on a non-Steam copy of the game can only use IP mode.

## 0.6.0
- Story missions in co-op (early). Start the campaign as usual; in the safehouse or in a mission press F4 → HOST: the level reloads from your last checkpoint with the server on, and your friend joins.
- The host leads the group. Picking a mission at the safehouse map table, the helicopter ride, the next level, "load last checkpoint", "restart level" — wherever the host's game goes, friends follow automatically (they reconnect on their own, ~30–40 s while the level loads).
- Story triggers are shared. Objective texts, doors and other scripted events the host sets off also run for friends; a friend walking into a trigger sets it off for everyone. Enemy squads are spawned only by the host and seen by everyone. Friends' games no longer autosave over their own campaign.
- Down & revive works in missions; if everyone is down, the group goes back to the last checkpoint.
- Partner's gunshots now have sound and muzzle flash for the host.
- Fixes: crashes during level changes (a stock UE4SS mod, CheatManagerEnabler, is now switched off; the mod no longer runs Lua for every spawned object); a broken network setting in Engine.ini could stop hosting silently — the mod and the installer now repair it.
- Still rough: cutscenes and some scripted scenes are not synced yet (planned for v0.7). Only the start of Cultists was tested in co-op so far.

## 0.6.1
- Partners now look like full soldiers. The host used to appear to friends as half a body (legs only) with a pistol floating in the air; now everyone sees the whole third-person character holding their gun.
- Partners walk. Bodies play walking / strafing animations as players move, instead of sliding frozen in one pose.
- Removed floating extra guns (a friend's own hidden copy and a duplicate gun on the host's body).
- The "NONE / NONE - 0" box no longer shows when you look at your partner (their marker shows the name).
- Animations are basic: no crouch, jump or melee poses for partners yet.

## 0.6.2
- Other players now appear as Subject 106 (the game's own 106 character model) instead of a generic merc soldier. Animations and the gun in hand work as before.
- Want the old look? Put model=soldier in ue4ss/Mods/T2Coop/config.txt.
- A partner's gun no longer has collision on the other machines.

## 0.6.3
- Every player's moves are now mirrored on the partner's body (checked from both sides):
- walking and strafing, sprinting, crouching and walking crouched, sliding, jumping, dropkick;
- looking up and down — the body raises or lowers its gun with the player's view;
- the grip matches the weapon (pistol, rifle...);
- dual wielding — a second gun appears in the partner's left hand (the pose stays two-handed: the game has no third-person dual-wield animation, so the guns are close together);
- the host's shots are now seen and heard by friends (before only the friends' shots reached the host). Not shown on the partner's body yet: reloading and the melee strike on the ground (those are first-person arm animations only).

## 0.6.4
- English install guide (README.txt) in the zip. Short version: unpack anywhere, run install.bat, start the game, press F4.
- Custom Horde maps: load any Horde map (also community maps that the arena list doesn't know), press F4 -> HOST - that map is hosted. Horde maps are now recognised by the Horde mode in the level, not by name.

## 0.6.5
- Players now look exactly as they dressed themselves in the safehouse — the game's own outfits (106, Patriarch, 107 and the rest you've unlocked) and the customization: jacket, gloves, pants and shoes colours and camo. Change it at the safehouse station (hold F) like in single player; partners see it within a couple of seconds.
- The jacket and gloves colours are also shown on the body (the base game only shows them on your first-person arms).
- look=106 in config.txt puts everyone in the Light 106 suit instead (the v0.6.2 look).

## 0.7.0
- Cutscenes for everyone. When a cutscene starts on the host, every player sees the same cutscene at the same moment (kept in step to about a tenth of a second). Partners are not written into the scene; after it, everyone gets control back next to the host. Joining in the middle of a cutscene starts it from there.
- Radio and dialogue lines (with the speaker's portrait and subtitles) are heard by all players, once.
- Doors: doors the host's story locks or unlocks are locked/unlocked for everyone, and doors that open on the host open for everyone - no more partners stuck behind a door only the host could open.
- Still to come: hostages, terminals / hacking, objective markers, elevators.

## 0.7.1
- When a cutscene is about to start, it now waits until every player has come to where it starts. Meanwhile everybody sees "WAITING FOR PLAYERS 1/2" (the count follows how many play) at the top of the screen and a "GATHER HERE" marker on the spot, and keeps playing normally. When the last player arrives, the cutscene plays for everyone at once and the level goes on.
- Cutscenes at the start of a level also wait for the players who are still reconnecting after the level change.
- The text is in Russian when the game is in Russian.
