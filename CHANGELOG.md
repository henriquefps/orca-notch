# Changelog

## Unreleased — fork of Coucou, stripped and rebranded as Orca Notch

Orca Notch starts from [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) at the merge of pull request #831 (`1e51809`). The history before that point lives upstream.

### Added

- Orca data in the island: the closed island shows three agent counters (spinner running, check-circle finished today, bell needs you), only the non-zero ones, and stays out of the way when everything is idle. The open island lists the workspaces flat, most urgent first, with state, repo, branch, PR, agents and time since activity, plus a usage footer per provider. Live data comes from `orca worktree ps` polled every 2.5 s while the island is visible and every 15 s when hidden or asleep (`docs/orca-polling.md`).

- Remote Orca servers: the notch discovers the servers you paired in Orca (`orca environment list`, refreshed about every minute) and reads each one with `--environment`, in parallel, with the same cadence as the local read and its own 10 s timeout. The closed-island counters sum the agents of every host; rows of a remote workspace carry the server's name as a small badge; a server that cannot be reached is marked offline in the footer while the others keep working. Settings gets "Include remote Orca servers" (on by default) and a toggle per server. Clicking a remote row brings its terminal forward on that server. Details in `docs/orca-polling.md`.

### Changed

- Closed island: half as wide (188 pt on a notchless screen, 240 pt with a notch; the height is unchanged), the three counters centered as one group, the mascot left of them (hidden if it does not fit). You can drag the closed island sideways along the top edge; the position is remembered per display (`islandPositions`), the open island opens anchored to it, and double-click or Settings > Display > Reset position brings it back to the default place.
- Closed island: the three counters are about twice as big (icon up to 20 pt, semibold digits) and each ear of the resting island is 148 pt wide, so nothing clips on screens with and without a notch.
- Clicking a workspace row in the open island brings that workspace's terminal forward in Orca (`orca terminal switch`, the only non-read command the notch runs).
- CPU with the island on screen drops from about 18 % to about 1 to 2 %: the mascot redraws at 2 to 20 fps instead of the display rate, the pointer is read from mouse events instead of a 60 Hz timer, the spinners run in Core Animation, unvisited island views are not mounted, and an unchanged Orca snapshot is not republished.
- The home view and the compact grid no longer show Claude Code session pills or the Claude/Codex plan pill; they show the Orca view instead.

### Removed

- Platforms: the Android app, the Windows and Linux (Tauri) app, the relay Worker, the iPhone app with its widgets, notification extension and phone link, the Homebrew cask, the GitHub Pages site and the README media.
- Features: Flow dictation and Parakeet, the Notetaker, crypto and portfolio, mail, Apple Music and Spotify, the Stripe, n8n, Notion, Resend, Cal.com and Vercel pollers, OK Coucou voice control, WhatsApp, chat providers other than Claude, the weekly recap, desktop mascot, wardrobe and outfits, greeting animation, machine vitals, screen capture, the in-app updater, demo mode, the Settings language picker and the App Store variant.
- All upstream artwork: the character, the app and menu bar icons and the 28 sounds.

### Kept

The notch island window and its state machine, display choice, hover and hide-when-idle behavior, the pill infrastructure, approvals and `AskUserQuestion` cards, terminal jump, global hotkeys, the Settings window, the hook server and its relay, the Claude chat, plan usage and the GitHub pulse.

### Changed

- Name **Orca Notch**, bundle identifier `dev.hfps.orca-notch`, support folder `~/Library/Application Support/OrcaNotch`, logs in `~/Library/Logs/OrcaNotch`.
- Hook payload fields renamed from `coucou_*` to `orca_notch_*`; generated agent plugins and config files are named `orca-notch`.
- The mascot is a placeholder whale drawn with `Canvas` (`NotchKit/Mascot.swift`), the icons come from `scripts/make-icons.swift`, and sounds are macOS system sounds (`SoundEngine.swift`).
- Single XcodeGen target, no third-party dependencies (FluidAudio removed).
