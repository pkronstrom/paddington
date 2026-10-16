# SMC-PAD: what the pad reports and what its buttons do

Notes on the M-VAVE SMC-PAD beyond plain MIDI: its settings memory, what SHIFT / NOTE REPEAT / the banks do, and
what Paddington can use. Measured on this pad (firmware identity `SMC-PAD_004`) on 2026-10-16, on top of the
protocol work in [spectalive/smc-pad](https://github.com/spectalive/smc-pad) (its `reference/FINDINGS.md` and
`docs/smc-pad-led.md`), which is where the pad-light protocol in `Sources/PaddingtonMac/LEDs.swift` comes from.

There is no public manual or protocol document from M-VAVE (searches find nothing); the official editor is
MidiSuite (macOS, USB only).

## How Paddington reads the pad

The pad-light session (GATT service `AE40`: write `AE41`, replies on `AE42`) is a request / reply protocol:
logical packets `00 59 <cmd> <len24-le> <data> <~sum(data)>`.

- `cmd 11`: identity. The reply is ASCII, here `SMC-PAD_004`.
- `cmd 23`: read. Data `<region> <addr32-le> <len24-le>`; the reply repeats that header and adds the bytes.
- `cmd 22`: write. Data `<region> <addr32-le> <len24-le> <bytes>`; the reply is `cmd 00` with `00` = OK.
- Region 4 = the 12-byte **global** block. Region 5 = the 8 **presets** (28,312 bytes).
- Global writes take effect at once and were all accepted (side-light test); whether they survive a power cycle
  is untested, so anything changed is written back.
- Writes are only accepted after the official app's connect session is replayed (`PadLEDs.unlock`). The pad answers
  roughly one read every 150 ms; faster requests are dropped (the unlock's own reads lose two in three).
- While the pad answers reads it also drops colour writes (sent without response), so the full preset dump is
  only read on request, one chunk per reply, and every colour is sent again afterwards.
- The keep-alive poll reads the global block twice a second. Paddington logs every change
  (`pad global: … — changed: [i] old→new` in `~/Library/Logs/paddington.log`).
- `paddington pad` shows the global bytes and the colour last sent to each pad; `paddington pad dump` saves all
  presets to `~/Library/Application Support/paddington/pad-config.bin`; `paddington pad set <byte> <value>` writes
  one global byte (restore it afterwards); `paddington pad probe [bytes…]` runs the light test below.

## The global block (region 4, 12 bytes)

This pad: `78 00 32 04 00 00 02 00 02 01 00 00`. spectalive's pad: `78 00 32 04 00 00 01 01 03 01 01 00`.

| Byte | Here | Meaning | Evidence |
|---|---|---|---|
| 0 | `78` | tempo 120 (BPM), probably with byte 1 as the high byte | NOTE REPEAT repeats every ~120 ms = 1/16 at 120 BPM |
| 1 | `00` | ? (tempo high byte?) | no visible change at 1 |
| 2 | `32` | swing 50 (%)? | value only |
| 3 | `04` | ? | no visible change at 0 |
| 4 | `00` | ? | no visible change at 1 |
| 5 | `00` | note repeat on (latched): 1 lights NOTE REPEAT | side-light test, step 6 |
| 6 | `02` | octave: which group of 16 pad records bank A shows (and, presumably, its notes): 2 = notes 36–51 (Paddington's colours), 1 = group 1 (stored yellow), 0 = group 0 (stored pale blue) | `pad probe 3 6`, `pad set 6 1`, preset dump |
| 7 | `00` | ? (spectalive: `01`) | no visible change at 1 (bank A) or 2 (bank B) |
| 8 | `02` | SHIFT + pad 9 / 10 / 11 / 12 sets it to 0 / 1 / 2 / 3 (probably the note-repeat rate) | experiment |
| 9 | `01` | ? | no visible change at 0 |
| 10 | `00` | active preset, 0-based: SHIFT + pad 1–8 | experiment (SHIFT + 3 → 2, SHIFT + 1 → 0) |
| 11 | `00` | pad bank: 0 = A, 1 = B (PAD BANK) | experiment |

Paddington uses byte 11: the pad bank is known as soon as PAD BANK is pressed (before, only from the next pad
press).

## The presets (region 5)

Eight presets of 3,539 bytes: five 23-byte button records, sixteen 6-byte knob records, then 128 26-byte pad
records (`<type> <ch> <note> 00 7F R G B FF …`), colour at byte 5. The pad records are 8 groups of 16:

| Group | Records | Notes | Stored colour (stock) | Shown when |
|---|---|---|---|---|
| 0 | 0–15 | 4–19 | `96C8F0` pale blue | bank A, octave byte = 0 |
| 1 | 16–31 | 20–35 | `F0F000` yellow | bank A, octave byte = 1 |
| 2 | 32–47 | 36–51 | Paddington's bank A | bank A, octave byte = 2 (default) |
| 3 | 48–63 | 52–67 | (Paddington wrote bank B here until 2026-10-16) | bank A, octave byte = 3 |
| 4–6 | 64–111 | 68–115 | green, red, cyan | higher octaves |
| 7 | 112–127 | 52–67 | `7878F0` lavender → Paddington's bank B | **bank B**, whatever the octave |

So a colour goes to `preset × 3539 + 211 + record × 26 + 5`: bank A note n → record 32 + (n − 36)
(`0x418 + (n − 36) × 26`), bank B note n → record 112 + (n − 52). spectalive's notes put bank B at records 48–63
(same arithmetic as bank A); that was never checked on a pad — here bank B showed group 7's lavender ("all white")
until the colours went to group 7.

- **Button record** (only `<` `>` `▶` `⏸` `●`, CC 25–29): `<type> <ch> <cc> <min> <max> <len> <SysEx…>`, e.g.
  `02 00 19 00 7F 06 F0 7F 7F 06 01 F7` = CC 25 plus the MIDI Machine Control message `F0 7F 7F 06 01 F7` (stop;
  `02` play, `03` deferred play, `04` fast forward, `05` rewind). The last byte is `FF` in preset 1; in preset 2
  the ▶ ⏸ ● records end in `5E 5D 5F` (94 / 93 / 95, the Mackie Control play / stop / record notes a DAW sends
  back to light those buttons) — possibly "light follows this incoming note". Untested.
- **Knob record**: `00 <type> <ch> <cc> <min> <max>`; 16 records = 8 knobs × 2 knob banks (bank B = CC 38–45).
- **No records** for SHIFT, NOTE REPEAT, PAD BANK, KNOB BANK or BT, and no colour or brightness field for any
  button.

This pad's presets:

| Preset | Pads (bank A) | Buttons | Knobs | Colours stored |
|---|---|---|---|---|
| 1 (in use) | notes 36–51, ch 10 | CC 25–29 | CC 30–37, ch 1 | Paddington's |
| 2 | other notes (24–27, 0–3, 8–11, 16–19…), type 4 | CC 46, 47, 94, 93, 95 (type 5) | CC 30–37, ch 1–8 | red, yellow, green… |
| 3–8 | same as preset 1 | same | same | stock blue / magenta |

So SHIFT + pad 2 would scramble Paddington's mapping; SHIFT + pads 3–8 change nothing but the stored colours.

## What the buttons do (experiment, 2026-10-16)

Each step about 3 s apart, with Paddington paused, watching the global block and raw MIDI (`paddington monitor`).

| Pressed | Global block | MIDI |
|---|---|---|
| PAD BANK, PAD BANK | byte 11: 0 → 1 → 0 | none |
| KNOB BANK, KNOB BANK | nothing | none |
| SHIFT alone | nothing | none |
| NOTE REPEAT alone | nothing | none |
| hold NOTE REPEAT + pad 1 (~2 s) | nothing | pad 1 note on/off every ~120 ms (15 hits), same velocity each time |
| SHIFT + pad 3, then SHIFT + pad 1 | byte 10: 0 → 2 → 0 | none |
| SHIFT + pad 9, 10, 11, 12 | byte 8: → 0, 1, 2, 3 | none |

Earlier observations (previous sessions, spectalive): SHIFT + pads 13 / 14 transpose, 15 / 16 change the octave
(15 + 16 resets), which silently shifts the notes the pads send — and, going by byte 6, the colour group bank A
shows. Paddington's device profile expects notes 36–67, so it doesn't follow octave changes (it resends its colours,
still to group 2); keep the octave at its default. The pad remembers its bank across power cycles.

## What can be used

Done:
- **Pad bank from the pad** (byte 11): known within half a second of pressing PAD BANK, and the legend follows it —
  the active bank's actions on the pad faces, the other bank's above, the frame in the shift style and PAD BANK
  outlined in bank B. Its colour key comes from both banks, so its height doesn't change.
- **Bank-B colours** go to record group 7, where the pad shows them.
- **Colours resent** after an octave or preset change and after `paddington pad dump`.

Later, if needed:
- **Pages via presets.** Presets 3–8 send exactly what preset 1 does, so SHIFT + pad 1 / 3–8 could switch
  Paddington between up to seven pages of layers, with nothing written to the pad. Needs: light colours written to
  the active preset (byte 10 → `PadLEDs.profile`), a warning on preset 2. A pick-one switch: pressing the current
  page's pad changes nothing, so it can't be a plain shortcut.
- **SHIFT + pads 9–12 as a four-way switch** (byte 8). Same pick-one limit; it also changes what is probably the
  note-repeat rate.
- **NOTE REPEAT + a pad = auto-repeat** at the pad's tempo. Already happens (each repeat fires the pad's action);
  it breaks hold actions. Telling it apart from a press needs the second hit (~120 ms).
- SHIFT alone, NOTE REPEAT alone and KNOB BANK can't be seen at all.

## Side-button and BT lights

The right-hand column (`<` `>` `▶` `⏸` `●`, banks, SHIFT, NOTE REPEAT) and BT are lit by the firmware. No preset
field controls them. `paddington pad probe` gives each global byte of unknown meaning (1, 3, 4, 5, 6, 7, 9) a test
value for 4 s (0, or 1 for a byte that is 0), puts it back, and toasts the step number for whoever watches the pad.

Result (2026-10-16): byte 5 lit NOTE REPEAT (note repeat latched on), and byte 6 (the octave) at 0 / 1 showed
record groups 0 / 1 — pale blue / yellow — instead of Paddington's group 2. Nothing dims or turns off the side
buttons or BT, so [sleep] can only darken the 16 pads. Byte 5 can't double as an indicator: it
turns note repeat on (pads would repeat).

Other leads: MidiSuite's SMC-PAD page (USB) would show whether a light setting exists at all; the preset-2 button
records hint that the ▶ ⏸ ● lights may follow incoming MIDI notes in that mode.
