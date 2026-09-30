# Changed — Online Co-op mod — MODLOG

## Target
- Game: **Changed** (Steam 814540), `F:\AASTIIM\steamapps\common\Changed`
- Engine: RPG Maker VX, RGSS2 (`RGSS202E.dll`, Ruby 1.8.1), 32-bit `Game.exe`, 544x416.
- No anti-cheat. Single-player game → modding the client is fine.
- Idea: **online co-op, 2+ players**. Host-authoritative. Game over only when *all* players are caught.

## Backup / restore
- `um backup create "F:/AASTIIM/steamapps/common/Changed" --name changed-install` → 
  `~/.universal-modder/backups/changed-install/20260930-210846.zip` (whole folder incl. Save1-5.rvdata in game root).
- Restore: `um backup restore changed-install`. Uninstall = put `Scripts=Data\Scripts.rvdata` back in Game.ini.

## Recon facts
- `Game.rgss2a` = RGSSAD v1, key 0xDEADCAFE (extractor: `tools/extract_rgss2a.py`) → `~/changed-decomp/game`.
- Scripts dumped: `~/changed-decomp/scripts/NNN_Name.rb` (99 sections). Custom ones: 089 Scene_Title (6 commands, lang),
  090 Scene_Guide, 091 Scene_Lang, 092 Fullscreen++ (aliases Graphics.update), 093 Save (saves in game root, 99 slots),
  094 steam (RestartAppIfNecessary(814540) → exit if not launched via Steam; CRC check of steam_api.dll),
  095 AntiLag VX (emap "x_y" → event ids, player registered as id 0; move_type != 0 events always update).
- Language: `Audio/lang.txt` (1..11). Data per language in `Data/DataN/`. Localized graphics get `_N` suffix:
  chars `$!03 $!07 $!13 $!14 $!15 $!16 $!19` (none for lang 1), pictures `67`/`68` (always `_N`).
- **Enemies** = event pages with move_type 2 (approach) or custom route containing code 10, trigger 1/2 (touch),
  list = `[123 set self-switch, (121), 0]` (190 pages). The next page is the autorun capture/transfur scene.
- Messages: Window_Message (vanilla VX). Pictures/tone/weather live in `$game_map.screen`.

## Route
Loader-less script mod: `Game.ini` `Scripts=Coop\Boot.rvdata`. Boot.rvdata (our own, one section) reads the game's
own `Data/Scripts.rvdata` from the archive via `load_data`, evals each, and evals `Coop/coop.rb` just before Main.
Nothing of the game is redistributed; the archive is untouched.

## Design (coop.rb)
- Transport: TCP via ws2_32 Win32API (non-blocking), framed `[len N][flag][payload]`, own safe serializer (no Marshal).
- Host runs the game. Clients: interpreter + event AI disabled; events are puppets driven by host diffs.
- Mirrored: event states, player states, screen+pictures, messages (host key presses advance client msgs),
  BGM/BGS/ME/SE, animations/balloons, switches/vars/self-switches/party, map transfers, game over.
- Clients' action/touch triggers are forwarded to the host, which validates and starts the event.
- Enemies chase the nearest alive player. Caught (not last) → becomes translucent "latex ghost" with the enemy sprite,
  can't trigger events. Teammate revives by pressing action next to them. Everyone revives on map transfer.
  Last alive caught → vanilla capture event runs → game over, clients follow.

## Log
- 2026-09-30: recon, extraction, design. Writing coop.rb v0.1.0.
- 2026-09-30: **RGSS2 ignores a loose Scripts= file while Game.rgss2a exists** ("Failed to load script.";
  proven by renaming the archive → loose file loaded fine). Fix: `mod/coop-install.ps1` APPENDS one entry
  `Coop\Boot.rvdata` to Game.rgss2a (key state continues from the last header; data untouched), saves the original
  length to `Coop/archive.len`, sets `Scripts=Coop\Boot.rvdata`. Uninstall truncates. Verified round-trip with
  extract_rgss2a.py (Boot bytes match, original Scripts intact). Game boots, CO-OP menu shows. PS 5.1 gotcha:
  hex literals like 0xDEADCAFE / 0xFFFFFFFF are Int32 → use decimal [uint64].
- Launching: Game.exe exits unless started by Steam (RestartAppIfNecessary). Use `um win launch --steam 814540`.
- Next: 2-player test (host + client). Needs a second instance (another PC, or steam_appid.txt for local test).
- 2026-09-30: **Relay ("bridge") on the dexx server**: `relay/relay.py` (asyncio) in container `changed-coop-relay`,
  `/opt/changed-coop-relay` (compose), public TCP `coop.dexx.moe:27500` (DNS-only record → 31.76.8.80).
  Protocol: host control `HOST <room>` → `OK`/`ERR`, `CONN <id>` per joiner; host opens data conn `ACCEPT <room> <id>`;
  joiner `JOIN <room>` then game frames; relay splices bytes. Unknown room → framed `[:reject, msg]`.
  Tested locally (`relay/test_relay.py`) and over the internet. Game: Mode=relay (default), Room code in coop.ini,
  pings every 300 frames.
- **Distribution on tool.dexx.moe**: `/opt/tool/public/{install-changed-coop.ps1, changed-coop.zip}` + section in
  index.html (backup `/opt/tool/index.html.bak.<ts>`). One-liner finds Changed via Steam libraryfolders.vdf,
  downloads zip, runs `coop-install.ps1 -Game .. -Source ..` (keeps existing coop.ini). Update path truncates only
  when our entry is found in the archive. Verified install / update / uninstall (size back to 80706208) on this PC.
- Next: real 2-player test. `tools/coopbot.py --room CODE` = headless Python client (joins via relay, follows host).
