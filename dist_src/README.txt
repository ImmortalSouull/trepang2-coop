TREPANG2 CO-OP  (unofficial mod, alpha)
=======================================
Co-op for Trepang2: Horde (Survival) mode and, since v0.6, the story campaign (early).
Русская инструкция: README.ru.md

INSTALL (every player)
----------------------
1. Close the game.
2. Unpack this zip anywhere (Desktop is fine) and double-click install.bat.
   It finds Trepang2 through Steam and installs everything (the UE4SS mod loader is included).
   You do NOT copy any files into the game folder yourself.
3. Start the game once. If the mod says "restart the game once" - restart it.

PLAY
----
Press F4 in the game (main menu or in a level) - the co-op menu opens.

  HOST        - start co-op. In the main menu: on the arena picked with "Next arena".
                On a Horde map (also custom maps): that map. In the safehouse or a
                story mission: that level, reloaded from your last checkpoint.
  JOIN        - type the host's address in the box and click Join.
  LEAVE       - leave co-op.
  INVITE      - Steam mode only: invite a Steam friend through the Steam overlay.
  LOOK        - your look for the others: safehouse outfit, or any enemy (about 330 variants
                in 30 factions: arrows = faction / variant), with a turning preview.

Everything is in the F4 menu (there are no other co-op keys).

CONNECTING OVER THE INTERNET
----------------------------
IP mode (default): the host opens UDP port 7777 on the router and gives the friend their IP,
or both players use a virtual LAN (Porthole, Radmin VPN, ZeroTier) and use the IP it shows.

Steam mode (experimental, no port forwarding): both players click "Switch IP / Steam" in the
F4 menu and restart the game. The host clicks HOST, then INVITE (STEAM) and picks the friend.

CAMPAIGN (early)
----------------
Play the campaign as usual. In the safehouse or a mission the host presses F4 -> HOST, the friend
joins. Wherever the host goes (mission start, next level, checkpoint, restart) friends follow.
If everyone is down, the group goes back to the last checkpoint. Cutscenes wait until every player has come
to where they start ("WAITING FOR PLAYERS 1/2" at the top of the screen, a marker on the spot), then play
for everyone at the same time, radio/dialogue lines and subtitles are shared, doors the story unlocks open for everyone.
Terminals, buttons, levers and scripted scenes (key F) used by anyone count for everyone; objective
markers show for all players. A partner can grab an enemy as a human shield; partner fire burns enemies.

SETTINGS
--------
Trepang2\CPPFPS\Binaries\Win64\ue4ss\Mods\T2Coop\config.txt
  look=player (everyone looks as they dressed in the safehouse) or 106 (Light 106 suit for all)
  enemy_hp=50 (host: enemies get +50% health for every extra player; 0 = off; also in the F4 menu)

UNINSTALL
---------
Delete dwmapi.dll and the ue4ss folder from Trepang2\CPPFPS\Binaries\Win64.

Source code and notes: https://github.com/ImmortalSouull/trepang2-coop
