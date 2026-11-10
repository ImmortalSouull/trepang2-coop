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

Keys: F4 menu, F5 host, F6 join, F7 leave, F8 next arena.

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
If everyone is down, the group goes back to the last checkpoint. Cutscenes are not synced yet.

SETTINGS
--------
Trepang2\CPPFPS\Binaries\Win64\ue4ss\Mods\T2Coop\config.txt
  model=106 (partners look like Subject 106) or soldier

UNINSTALL
---------
Delete dwmapi.dll and the ue4ss folder from Trepang2\CPPFPS\Binaries\Win64.

Source code and notes: https://github.com/ImmortalSouull/trepang2-coop
