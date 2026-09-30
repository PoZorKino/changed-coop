Changed Co-op 0.1.0 - online co-op for Changed (Steam), 2+ players
==================================================================

Install (PowerShell, auto-finds the game):
    irm https://tool.dexx.moe/install-changed-coop.ps1 | iex
or manually: close the game, then run
    install.bat "C:\...\steamapps\common\Changed"

Play:
  * Title screen -> CO-OP.
  * Host: "Host game", then New Game / Continue as usual. Tell friends your Room code.
  * Friends: set "Room:" to the host's code, then "Join game". They drop into the host's game.
  * Connection goes through the relay coop.dexx.moe:27500 - no port forwarding needed.
    ("Via: direct IP" is also available: the host must open TCP 27500.)
  * Everyone needs the same mod version.

Rules:
  * The host's game is the real one (story, events, saves). Only the host saves/loads.
  * Enemies chase the nearest living player.
  * Caught players turn into a latex ghost. A teammate revives them by pressing the action key next to them;
    everyone is also revived when the group changes map.
  * Game over only when EVERY player has been caught.

Uninstall: uninstall.bat "C:\...\steamapps\common\Changed"  (or $coopUninstall=1; irm ... | iex)
The installer appends one small entry to Game.rgss2a and uninstall removes it again; Steam "Verify integrity"
also restores the original. No game files are included in this mod.

Made with Claude Code (AI-assisted). Not affiliated with DragonSnow.
