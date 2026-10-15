# padctl

A macOS menu-bar app that turns a MIDI pad (first: M-VAVE SMC-PAD over Bluetooth) into a context-aware control surface. Layers, devices and smart buttons are TOML files in `~/.config/padctl/`.

Design: [docs/plans/2026-10-14-padctl-phase1-design.md](docs/plans/2026-10-14-padctl-phase1-design.md) · Plan: [implementation](docs/plans/2026-10-14-padctl-phase1-implementation.md) · [MASTERPLAN](MASTERPLAN.md)

## First run

```sh
./scripts/build-app.sh      # builds ~/Applications/Padctl.app (+ padbeat), links ~/.local/bin/padctl; a running app restarts itself
padctl init                 # copies the default config (never overwrites)
padctl start                # menu-bar icon (a 4×4 pad grid) appears; grant Accessibility + Bluetooth when asked
```

1. **Connect the pad:** press BT on the pad. padctl scans and connects by itself; if it doesn't within ~20 s, padctl menu › *Bluetooth MIDI window…* and click Connect there.
2. **Teach padctl your pad:** `padctl learn` — press each pad, turn each knob right then left, press each side button (Enter skips one that sends nothing). It writes `~/.config/padctl/devices/m-vave-smc-pad.toml`; the app reloads it.
3. **Agent status:** `padctl hooks install` adds observe-only hooks for Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`); backups are saved next to each, and `padctl hooks uninstall [claude|codex]` removes exactly those entries. In Codex, run `/hooks` once and trust the padctl entries. New sessions report status.
4. **Context meter + plan usage (optional):** in `~/.claude/statusline.sh`, right after `input=$(cat)`, add
   `echo "$input" | padctl statusline-tap >/dev/null 2>&1 &`
   The Compact pad then shows context use (green < 50 %, yellow, red > 80 %) and the legend header shows 5-hour / 7-day usage.
5. **Start at login + crash restart:** padctl menu › *Start at login · restart after a crash* (a launchd agent; Quit from the menu stays quit). Context changes and tmux errors are logged to `~/Library/Logs/padctl.log`.
6. **Check:** `padctl doctor`.

## Using it

Same spot = same kind of thing in every ruleset (Default, tmux, Claude Code, Codex):

| | left | right |
|---|---|---|
| knobs row 4 (7, 8) | Model | Thinking level |
| knobs row 3 (5, 6) | Scroll / scrollback | Zoom / font size |
| knobs row 2 (3, 4) | Windows / tabs | Panes / app windows |
| knobs row 1 (1, 2) | ↑ ↓ | ← → |

- **Pads, rows 1–2:** slots: tmux windows 1–8 — blue, or the agent's status: cyan working, yellow needs input / magenta needs approval (blinking), green finished (not seen yet), white idle (seen), red error (Default: editing keys).
- **Row 3, lifecycle:** New… (the options list: Codex, Claude + Codex, **Claude/Codex worktree with a dictated task** (`workmux add -A`), project folders…) · Zoom (the pane fills the window) · New (green; tap: Claude left, shell right in `~/Projects/own`; **hold: a shell here**) · Close… (red; hold 1 s → close window / workmux close / merge / remove worktree). Waiting agents: their window pads blink.
- **Row 4, the app's verbs** (bank B above each): Claude: Compact (/clear) · Rewind (/resume) · Prompts… (Mode) · Skills… (/handoff); Codex: Compact (/new) · Backtrack (/status) · Prompts… (Approvals) · Commands… (/mention). Prompts are Markdown files in `~/.config/padctl/prompts/` (front matter `label:`, then the text; pasted without Enter) — tap for the list, hold or ● + Prompts… to search.
- **Buttons:** < > prev/next window · ▶ Enter (hold 250 ms: legend) · ⏸ Esc on press · ● Talk (VoiceInk: hold to talk, or double-tap for hands-free — then ● again stops and pastes, ▶ stops, pastes and presses Enter).
- **Legend** (hold ▶, tap to pin) looks like the pad itself: knobs, pads and side buttons in their real places, coloured like the pad lights (other windows dimmer, the current window outlined). The grey text printed above a pad or knob is its bank-B action. Size: `config.toml [legend] scale`.
- **PAD BANK B / KNOB BANK B** = shift layers. The banks send no MIDI themselves, so padctl only learns the bank from the next press; the legend therefore always shows bank A on the pad face and bank B printed above it (the pad's own lights are right for both banks).
- **Panes:** knob 4 turns through the panes of the current tmux window (bank B pads 1–4 = pane 1–4); the layer follows the pane, Claude ↔ Codex.
- **Drums:** a window pad whose tmux window doesn't exist plays a Roland TR-707 sample (public domain, `sounds/tr707/`). Drums go to the empty pads in priority order — kick, snare, hat, open hat, clap, low tom, high tom, cowbell — so two empty pads already make a beat and more pads add to it. Its light stays dark. Change sounds in `config.toml [sounds]`, or the pads in `tmux.toml` (`empty = { … }`). Knob bank B = volume, desktops, app windows.
- **Lists** (model, thinking, skills, mode, New…): any knob moves, any pad or ▶ selects, ⏸ or "✕ Cancel" cancels.
- **Skills…** lists active skills, then the skill vault (◇, `~/.skill-vault` → types `/vault-skills <path>`) and the MCP vault (⧉, `~/.mcp-vault` → `/vault-mcp use <name>`). **Search:** hold ● Talk and press Skills… (or hold Skills…): the list gets a search row on top — type, or say the skill and release ● (VoiceInk's transcript is picked up). A clear match is typed in by itself; otherwise the search row stays highlighted, ▶ takes the top match, knobs move into the results. Matching is fuzzy and sound-alike (Cyrillic transcripts too). Spoken forms work ("vault skills", "context seven", near-misses). `padctl items skills [words…]` shows the list or the ranking.
- **Combos:** any binding can take `with = { <held control> = { <action> } }` — what it does while another control is held (e.g. `with = { rec = { search = "skills" } }`).
- **Menus** (Rewind, /resume, Approvals, Codex /model): knobs move, any pad selects, ⏸ backs out.
- **Claude asks a question:** pads 1–4 become the answer options (needs `padctl hooks install`).
- **Browser** (Firefox, Chrome, Safari, Brave, Arc): pads 1–8 tabs · row 3 Reopen tab · Address bar · New tab · Close tab (hold 2 s quits) · row 4 Google · DuckDuckGo (hold: search the selection) · ChatGPT (⌥Space; hold ⌥⇧1) · Claude quick entry (double-tap ⌥ — match it to your Claude setting). Bank B: Find, Bookmark, Back, Forward, Reload, DevTools…
- **Pad lights** (over Bluetooth, from [spectalive/smc-pad](https://github.com/spectalive/smc-pad)'s protocol): bank A = normal layer, bank B = shift layer; windows show agent status, waiting pads blink, the current window is brightest. Seven distinct hues only; set colours/brightness in `config.toml [led]`. Full brightness by default (readable in daylight); padctl menu › *Dim pad lights (night)* scales everything down (`night = 0.3`).
- **Menu-bar icon:** a 4×4 pad grid — solid = pad connected, faint = not connected; a number next to it = agents waiting, `!` = config error.
- **Keys follow your keyboard layout** (⌘+, ⌘[ … work on a Finnish layout); tabs use ⌃⇥, app windows switch through Accessibility.
- **Sounds:** each group has a quiet sound (windows a soft click, actions Pop, skills Bottle, close Basso, New Hero, errors Funk); set in `config.toml [sounds]` or per binding with `sound = "..."`.

## Editing layers

Every file under `~/.config/padctl/layers/` is a layer; folders group a ruleset with its `prompts/` and `scripts/`. Save → the app reloads; a broken file keeps the last good config and shows the error in the legend and menu. See the comments at the top of `layers/default.toml` for the binding syntax. `padctl apps` prints the bundle id for a new ruleset's `when`.

## Development

```sh
swift test                  # core engine tests (no hardware)
padctl monitor              # raw MIDI + what it maps to
padctl simulate pad3        # drive the running app without the pad
```

Test mode for the app without touching real apps: `PADCTL_TEST=1 PADCTL_TMUX_SOCKET=<name> PADCTL_FAKE_APP=com.googlecode.iterm2 PADCTL_CONFIG=$PWD/config .build/debug/padctl run`.
