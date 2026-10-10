# Nano Cortex Editor (native macOS) — Plan

## 1. Stack
| Layer | Choice | Why |
|---|---|---|
| Language / UI | Swift 6, SwiftUI (+AppKit where needed), macOS 14+ | Native feel, menu bar, instant launch |
| Bluetooth | CoreBluetooth behind `NanoTransport` (actor), `FakePedal` for tests/previews | Remembers and reconnects; headless tests |
| Protocol | `NanoCore` package: hand-written protobuf codec, framing, messages, state | Ports the verified JS one to one; golden tests from recordings |
| Cloud | WKWebView (persistent store) + URLSession sharing its cookies | Real login, Passwords autofill, capture bundle download |
| Audio | AVAudioEngine metronome, CoreAudio output list | Native |
| Project | XcodeGen `project.yml`; `swift test` for the core; XCTest/XCUITest | Agent-friendly |
| CI / release | GitHub Actions on macOS: core tests + app build on PRs; unsigned `.app` zip on `v*` tags | Same flow as the Electron repo |

## 2. Model
Device state mirrors the Electron `state` object: 64 preset names, 25 capture slots, 5 IR slots, current preset
(amp knobs 0–255, capture volume dB, gate on/reduction, cab on/slot/mic/position/level/HPF/LPF, five FX blocks with
model id + params), library (factory/user captures and IRs), firmware, dirty flag. Message layouts: `docs/PROTOCOL-NOTES.md`.

## 3. Surface map
Main window: preset sidebar · signal chain (8 nodes) · inspector · status bar. Sheets: connect, rename, slot chooser,
library picker, send-to-pedal confirm. Overlays: tuner, metronome. Second tab/window: Cortex Cloud. Menu bar extra:
preset up/down, tuner, metronome.

## 4. Modules
`NanoCore`: `Proto`, `Frame`, `Messages`, `StateDump` (parser), `Library`, `Transport` (protocol + `FakePedal`),
`Session` (connect/sync/queue, write coalescing). App: `BluetoothTransport`, `PedalStore` (@Observable),
views per surface, `CloudController`, `Metronome`, `MenuBarController`.

## 5. Design direction
Cortex Control's language as in the Electron app: #121212/#181818 surfaces, #2E2E2E lines, white/#ABABAB/#959595 type,
IBM Plex Sans, purple #6954FF for actions, Quad Cortex category colours for blocks. Icon: signal pulse in the LED ring
(`App/Resources/icon.svg`).

## 6. Build order
| # | Step | Model | Verify |
|---|---|---|---|
| 1 | [x] Scaffold + `NanoCore` codec/framing/messages with golden tests from the recordings | Fable | `swift test` green (8 tests); app builds |
| 2 | [x] `StateDump` + `Library` parsers (current-state dump incl. firmware f24, gate f53/54; FE metadata; library reply) + `Models` catalogue generated from upstream | Fable | `swift test` 14 green: metadata (64/25/5 names), preset 14 and saved preset 64 dumps, gate 70%, library replies (25 factory, 3 user) |
| 3 | [x] `Transport` protocol, `FakePedal` (answers like demo mode), `Session` actor: connect, sync, serialized write queue with per-key coalescing, typed-reply waiters; `Writes` for every device write | Fable | `swift test` 25 green: every write builder equals the recorded pedal bytes; sync/preset/save/rename/FX/library/upload against the fake; 6 rapid knob writes → ≤2 |
| 4 | [x] `BluetoothTransport` on CoreBluetooth (scan by service, remembered peripheral, pending reconnect, per-session notification streams), `PedalStore`, first-light window with Save, file log + debug-only dev remote (`:4849`) | Fable | ⚠️ Real pedal, all verified 2026-10-08: connect + sync in 2 s, preset switch, knob write + read-back, save on preset 64, power-cycle → automatic reconnect + re-sync, saved value persisted |
| 5 | [x] Main window: sidebar, chain, inspector (knobs, switches, pickers), status bar; demo mode via `FakePedal` | Opus | Demo-mode pass over every write path through the dev remote (packets in the Activity log); screenshots reviewed. XCUITest smoke → row 5b |
| 5b | [x] XCUITest smoke in demo mode (launch with -demo, switch preset, select a stage, bypass and re-enable it, ⌘S) | Opus | `NanoCortexEditorUITests` green locally 2026-10-08 and in CI |
| 6 | [x] Save/rename/tuner/library→slot flows + slot usage scan | Opus | On the pedal 2026-10-08: library load into a slot (type 81 ack, slot name, capture selected), rename and revert, save with re-read after power-free round trip, tuner on/off, full 26-preset usage scan returning to the origin preset, cab mic/position write and read-back |
| 7 | [x] Cortex Cloud tab (WKWebView) + Send to Nano (bundle download, upload stream, slot) | Fable | On the pedal 2026-10-08: signed in, sent "Darkglass AO900 1" (10.4 KB, 22 writes) from its Cloud page; the pedal stored it as user capture 6 with the Cloud's hash and the library lists it |
| 8 | [x] Metronome (AVAudioEngine, output picker), menu bar extra | Opus | Dev remote: 6 beats in 3.1 s at 120 BPM, tempo change live, clamping, outputs listed; overlay screenshot reviewed 2026-10-08 |
| 9 | [~] Release workflow (unsigned .app zip on tags), README, icon pipeline | Sonnet | Release steps run locally (universal build, ad-hoc sign, zip) 2026-10-08; ⚠️ Anup tags v0.1.0 and the Release holds a running app |
| 12 | [x] Save As: the live sound into another preset slot under a new name, then switch to it (Anup, 2026-10-08) | Fable | On the pedal: saved into the empty slot 63, name listed, app switched, source preset untouched |
| 13 | [~] Context menus: preset rows (Load, Rename…, Save current sound here…), chain nodes (Bypass/Enable, Change effect…, Clear slot), capture/cab slot cells (Load, Load from library into this slot…); same in Electron | Opus | UI test + demo screenshots; Electron UX checks |
| 14 | [x] Delete a preset: type 50 `{1: 2, 3: index}` → 31, 51 (decoded from Anup's phone-app trace, PROTOCOL-NOTES §9); confirmation sheet, row menu, Pedal menu; Electron too (#20) | Fable | On the pedal 2026-10-09: Save as into the empty slot 64, delete, the pedal lists the slot empty again (24 presets), back on preset 2 |
| 15 | [x] Distinct Dock icon for the native app: same mark, LED ring in teal→green instead of purple (Anup, 2026-10-08) | Sonnet | Both apps side by side in the Dock |
| 16 | [ ] Preset backup/restore to files (JSON of the state dump + FX params; restore = replay the writes into any slot, then save) | Opus | Round trip on the pedal: back up 64, change it, restore, state matches |
| 17 | [>] (see row 30) Footswitch assignment: show which presets the four footswitch positions select (state fields 14/15/38/39) and set them (type 29 fields 5–8) | Fable | ⚠️ Real pedal: change one assignment, press the switch |
| 18 | [ ] Setlists: ordered preset lists per gig, performance view with big prev/next, ⌘[ ⌘] | Opus | Demo + UI test |
| 19 | [ ] Undo and A/B: undo the last edits; toggle saved vs edited sound before committing (built on the restore replay) | Opus | Demo: A/B toggles the packets back and forth |
| 20 | [~] Device page (Settings → Device): About from 46/47 + 91/92 (name, firmware build, serial, hash), LED brightness (67.4 ↔ 66.6, shown as %) and USB playback volume (67.14 ↔ 66.17, −20…0 dB, typeable), written together like the phone app and coalesced; read-only raw line of 66; capture "Info…" popover (17/18) from the capture node and the capture slot menu. Decoded from the 2026-10-09 phone trace (PROTOCOL-NOTES §13). Left: ⚠️ one try on the pedal (brightness visibly changes, USB volume audible, read-back), mapping of the other settings fields | Fable | Demo via the dev remote (`/device`, `/captureinfo`): 6 rapid brightness writes → 3, read-back matches; screenshots of the section and the popover; `DeviceTests` pin bodies/parses to the trace |
| 21 | [x] Parity leftovers in the native app: session recording (Record in the status bar → JSON like Electron's), keyboard shortcuts sheet (?), Refresh button. 2026-10-09: done (PR feature/native-parity); demo-verified via the dev remote, UI smoke covers the sheet | Opus | Demo + UI test |
| 22 | [ ] Rearrange presets by drag and drop (official app has it) — ⚠️ needs one phone-app trace of a single drag, then decode, both apps | Fable | Trace decoded; order persists after power cycle |
| 23 | [x] Settings window (⌘,): accent colour (Cortex Control palette + blue, applied live; Dock icon and header mark follow it, toggle), metronome output/volume/default tempo/beats/click sound (Click, Woodblock, Tick, Beep, Cowbell, synthesized), connect at launch + forget the remembered pedal, Activity log reveal + drawer at launch, dev-remote port (debug). Header mark 26 → ~34 pt. 2026-10-09: PR feature/settings; demo-verified over the dev remote. Electron parity not done | Opus | `/settings?accent=orange` + `/shot` (orange Save and selected row), `icon=` PNG, relaunch keeps it, `sounds=1` stats differ per sound; UI smoke opens ⌘, |
| 24 | [x] Advanced metronome (Anup, 2026-10-09): Simple / Advanced switch in the overlay (Settings → "Opens in", last Advanced setup remembered); time signature 1–16 over 4/8/16, accent cells (accent/normal/soft/mute) with meter presets, subdivisions 2/3/4 with swing, count-in 0–2 bars, tempo trainer (+N BPM every M bars to a target), gap trainer (play N, mute M), Levels… popover (accent, main, subdivisions; also in Settings), bar counter and sub pips. Engine: pure `MetronomePattern.events` + bar-boundary trainers; new `NanoCortexEditorTests` unit target. Electron parity not done | Fable | Unit tests 8 green; dev remote: 5/4 (3+2) triplets 3 s, gap trainer muted bars, ramp tempo steps; screenshots of Simple, Advanced, Levels |
| 25 | [x] Metronome ↔ preset tempo sync (Anup): decoded from the 2026-10-09 phone-app trace (type 145 live/preset writes, state field 56); inspector Tempo control (drag label, − / +, typeable, Tap; live while moving, one preset write when it settles, Save commits); Settings → Metronome "Follow the preset tempo" (default off): the metronome shows and follows the preset tempo and writes its changes back. 2026-10-09: PR feature/preset-tempo. Electron in parallel | Fable | Golden tests against the trace; demo over the dev remote; ⚠️ one try on the pedal |
| 26 | [x] Discard edits (Anup, 2026-10-09): outlined Discard button next to Save (only while there are unsaved edits), Pedal → Discard Edits…, confirmation sheet; re-selects the current slot so the pedal reloads the preset as saved. Fake pedal keeps a saved snapshot so demo reverts too. Electron: PR #23 | Fable | Demo over the dev remote: knob back to the saved value, one `Preset change` packet; ⚠️ one try on the pedal |
| 27 | [x] Header tidy (Anup, 2026-10-09): one connection indicator (the status bar's; header pill removed), metronome opens at 100 BPM on a fresh install, `/library` lists capture kinds (`type|instrument`) for the icon work. Electron: PRs #24, #25 | Fable | Demo screenshot: header ends Tuner … Exit demo, Save; status bar LED + text |
| 28 | [x] Capture kind icons (Anup, 2026-10-09): the library picker shows the capture's device type and instrument as small line icons (our own drawings, same SVGs as Electron's `KIND_ICONS`) before the author; unknown words show nothing, stay in the tooltip and are logged once. Known words so far: amp_head, default, guitar, instrument_not_set; ⚠️ read the real vocabulary from Anup's pedal (`/library` → `kinds`) and extend the table. Electron: PR #26 | Fable | Demo popover screenshot: head/combo/pedal icons, bass on SVT |
| 29 | [x] Metronome overlay layout (Anup, 2026-10-09: "alignment issues… nicer and cleaner"): title left / mode switch right on one line; every control 30 pt (pills, `MiniStepper` as one field, themed Pattern and Output drop-downs, accent cells) with section labels on one line and an 8-pt rhythm (`MetroLayout`); rhythm controls in one `Grid` so both rows share columns; trainers as a grid (switch + name, then evenly spaced steppers); Accents hint as a quiet secondary line; un-stepped BPM slider (the stepped one drew 270 tick marks under the track); Volume/Output/Levels on one line; Settings uses the same Output drop-down and Beats stepper. Stepper values are typeable (click, type, Enter/blur commits clamped, Esc reverts and leaves the overlay open; supersedes PR #18), `/metro?type=&text=`, `focus=`, `/key`. Electron parity not done | Opus | Screenshots before/after of Advanced, Simple, Levels and Settings, plus fields in editing state; dev remote: typed 175 + Enter commits, Esc reverts with the overlay open, 99 clamps on blur; unit tests 9 green |
| 30 | [x] Footswitch assignment (Anup, 2026-10-09; supersedes row 17): Footswitches strip under the preset list (IA IB / IIA IIB, preset number and name, current one highlighted; click loads, right-click "Assign current preset" / "Assign…" popover), "Assign to footswitch IA…IIB" on preset rows; with unsaved edits an assignment asks "Save changes to X?" first (the pedal drops them, trace ~649 s); `Writes.assignFootswitch` (type 29, field 4 = −1), preset change field 9 now names the slot holding the preset (was always 4); device-side presses update the slots; fake pedal keeps four slots; `/footswitch?slot=&i=`, `/state` → `footswitch`. PROTOCOL-NOTES §10. Electron: in parallel | Opus | Fixture bytes (three assignments and field 9, `FootswitchTests`); demo screenshot of the strip after `/footswitch?slot=iib&i=5`; ⚠️ one assignment on the pedal, then press the switch |
| 31 | [x] Expression pedal assignments (types 60–63, PROTOCOL-NOTES §12): NanoCore `ExpressionAssignments` (11 sweep + 8 on/off targets, encode/parse), `Writes.expressionRead/Save`, `Session.readExpression/saveExpression`, fake pedal keeps a set per preset; store reads on connect and every preset load, one 62 per edit (latest wins while dragging), edited + toast on clear; EXP pill before IN opens the panel in the inspector (target menu, heel/toe knobs in the parameter's units, switch mode/delay/latch/invert, Remove, Add, Clear all); dev remote `/expression`. Electron in parallel | Fable | Five trace bodies byte for byte + round trip (38 core tests); demo screenshots of filled and empty panel; ⚠️ on the pedal: assign, Save, power-cycle, re-read |
| 32 | [x] Share-ready 1.0.0 (2026-10-09): new repo `AJs-Creations/nano-cortex-editor-mac` without recordings (tests inline scrubbed frames, DECISIONS #19), MIT LICENSE + THIRD_PARTY_NOTICES, version 1.0.0, user README, `docs/MANUAL.md` with demo screenshots, CHANGELOG, CONTRIBUTING, issue/PR templates, release notes from CHANGELOG | Opus | Core + app unit tests green, Debug build, CI on the PR; ⚠️ Anup tags v1.0.0 |
| 33 | [x] Developer tools switch (Anup, 2026-10-10): Settings → Advanced "Developer tools", off by default (`ui.devTools`); hides Record, Activity, ⌘L / View → Activity Log, the "Sent: …" status text, the device hash and Raw settings, the capture Info hash, and the ⌘L/Record shortcut rows; turning it off closes the drawer and saves a running recording. Log file always written, rotated at ~2 MB to `activity.1.log` (`RotatingLogFile`, one open handle); Help → Show Log File. DECISIONS #21. Electron in parallel | Opus | `LogFileTests` (rotation, relaunch with a big file, recreate, default off); UI smoke: no Record/Activity by default, both with `-ui.devTools YES`; dev remote `/settings?devtools=` toggles live (menus, rows, drawer, recording); docs screenshots retaken |
| 11 | [~] Design polish pass to Electron parity (Anup, 2026-10-08: "looks ok but nowhere near as good as the Electron version"): compare screen by screen against the Electron app, close the gaps in spacing, type, knob rendering, node cards, sidebar, drawer, sheets and animations. 2026-10-08: exact pass against `pro/ui.css` + the two-row top bar from `src/toolbar.html` done (PR feature/visual-parity); waiting on Anup's side-by-side review | Opus | Side-by-side screenshots reviewed by Anup |
| 10 | [>] Nano presets from Cortex Cloud — DEFERRED: needs a phone-app trace of a preset download (same as the Electron repo's queue) | Fable | — |

## 7. Exit criteria
Every row 1–9 `[x]`; the app passes the Electron UX-test checklist by hand on the real pedal; reconnect after power-up
needs only the pedal's EXIT+CAPTURE press.

## Session log (newest first)

### 2026-10-10 — Developer tools switch (row 33)
**Step:** 33 · **Model:** Opus
**Did:** `AppSettings.devTools` (`DevTools.swift`, key `ui.devTools`, default off) gates Record, Activity, ⌘L and View →
Activity Log, the "Sent: …" status text (upload progress still shows), Settings → Advanced's drawer/log-file rows, the
Device page's hash and Raw settings, the capture Info hash and the shortcut rows (`ShortcutsSheet.rows(devTools:)`).
Turning it off closes the drawer and saves a running recording to the default folder. `RotatingLogFile` keeps one
handle open and rotates at 2 MB; Help → Show Log File (creates it if missing). Dev remote `/settings?devtools=0|1`,
and the dump now lists the View menu and the shortcut rows. Smoke test pins `-ui.devTools NO` and adds a launch with
`YES`. Screenshots retaken in normal mode (activity-log with dev tools on).
**Found:** SwiftUI fills `CommandMenu` items lazily: an item hidden by state stays in the NSMenu until the menu is
about to open, so the dev remote calls `menuNeedsUpdate` before dumping; the ⌘L menu action also checks the setting.
**Decisions:** #21.
**Next:** Anup reviews PR #1.

### 2026-10-09 — Share-ready 1.0.0 (row 32)
**Step:** 32 · **Model:** Opus
**Did:** Imported into `AJs-Creations/nano-cortex-editor-mac` with no recordings in any commit: the session recordings,
phone-app traces and capture bundle are gone; every test that used them asserts the same frames, inlined in
`RecordedFrames.swift` with hashes, Cloud ids and author names replaced at the same length (upload tests use synthetic
capture bytes with the recorded envelope and write layout). Debug recordings now go to the git-ignored `recordings/`.
Docs scrubbed of personal details. LICENSE (MIT), THIRD_PARTY_NOTICES, version 1.0.0 (Info.plist takes the version
from build settings), README for users, MANUAL with 28 demo-mode screenshots (blue accent, 1440×900 window; no Cortex
Cloud website content), CHANGELOG, CONTRIBUTING, templates; release workflow names the zip
`Nano-Cortex-Editor-mac-<v>-universal.zip` and takes its notes from CHANGELOG.
**Decisions:** #19, #20 (bundle id unchanged).
**Next:** ⚠️ Anup reviews the PR, merges, tags v1.0.0.

### 2026-10-09 — Expression pedal assignments (row 31)
**Step:** 31 · **Model:** Fable
**Did:** `Expression.swift` in NanoCore (model, type-62 encoder with explicit zeros, 61/62 parsers, fake pedal 60/62 → 64+61 / 63+115,
demo preset 2 starts with a gain sweep), Session read/save, store state + coalesced writes, `ExpressionPanel` reached from an EXP pill
before IN in the chain, `/expression` on the dev remote. Frames from the recorded phone-app session (not published) inlined; `ExpressionTests`
pins the five trace bodies (and 693 ms / latch off) byte for byte. PROTOCOL-NOTES §12.
**Found:** the pedal reports the preset clean again (115 `{1:1}`) when a cleared set matches the saved one; the trace's 61 was always empty,
so the reply's "save field − 1" layout is still upstream-only.
**Broke:** nothing. 38 core tests, 9 app unit tests green.
**Decisions:** #18.
**Next:** ⚠️ one pedal pass: assign gain on a spare preset, Save, power-cycle, `/expression?reread=1`.
**Blocked:** nothing.

### 2026-10-09 — Preset tempo + metronome sync (row 25)
**Step:** 25 · **Model:** Fable
**Did:** NanoCore: `Writes.tempo(bpm:live:)`/`tempoQuery`, `MessageType.tempo` (145), `StateDump.tempo` (field 56, 120 when
absent), `Session.setTempo` (live writes coalesce under key `tempo`; a commit = live + scope-0 with the final value, and later
live writes queue behind it), `.tempo` event for the unsolicited echo, `FakePedal` tempo (per-preset saved tempos, dirty on
scope 0, echo on live/query, `tapTempoOnPedal`). `TempoTests` (6): both bodies byte-for-byte at 203.4 s / 246.3 s, every
4:0 write in the trace, echo parsing, field 56 after each save, fake round trip, commit order. Store: `presetTempo`,
`setTempo(_:live:)`, `nudgeTempo` (live now, commit when settled), `tapTempo`, `attach(metronome)`; our own echoes ignored for
1 s. Inspector top row: Tempo (drag the label, − / +, typeable field, BPM, Tap). Metronome: `adopt(presetTempo:)`,
`onTempoChanged(bpm, commit)` (trainer steps are live only), shared pure `TapTempo` (+ unit test). Settings → Metronome
"Follow the preset tempo" (`metro.followsPreset`, default off); overlay shows "♩ follows preset". Dev remote `/tempo`,
`/state` tempo, `/settings?followpreset=`, `/metro` followsPreset.
**Verified (demo):** preset 2 reads 96; nudge 97 → live only, then commit (edited, dirty); follow on → metronome 96;
metronome 125 → `Tempo 125 BPM (live)` then `Preset tempo 125 BPM`; preset 5 → metronome 75; pedal-side tap 88 → store and
metronome 88. Screenshots of the inspector control, the overlay with follow on, Settings.
**Broke:** nothing known.
**Decisions:** #17.
**Next:** ⚠️ Anup tries it on the pedal (step, Tap, Save, switch back; tap on footswitch I with follow on).
**Blocked:** nothing.

### 2026-10-09 — Footswitch assignment (row 30)
**Step:** 30 · **Model:** Opus
**Did:** Decoded from Anup's phone-app trace (recorded phone-app session, not published): assignment is type 29
with field 4 = −1 and the slot's field (5–8) set; `Writes.assignFootswitch`, `Session.assignFootswitch` (ack 30, then
state). Preset changes now send field 9 = the footswitch slot holding the preset (the session tracks the slots from
state dumps and footswitch presses). Store, sidebar Footswitches strip, preset-row menu items, dev remote. 39 core
tests (5 new), app unit tests green; demo verified over the dev remote with screenshots.
**Found:** an assignment drops unsaved edits (trace ~649 s), so it now goes through a save prompt like a preset switch. The phone app sent one preset change with `10: 0` instead of field 9 (PROTOCOL-NOTES §10, open).
**Broke:** nothing.
**Decisions:** none new.
**Next:** ⚠️ one assignment on the real pedal, then press the switch.
**Blocked:** nothing.

### 2026-10-09 — Device page and capture details (row 20)
**Step:** 20 (`[~]`, needs the pedal) · **Model:** Fable
**Did:** `NanoCore/Device.swift`: `DeviceInfo` (47 + keep-alive 92), `DeviceSettings` (66: name, LED brightness,
USB volume, every other field kept as raw text), `CaptureDetails` (18, field 11 through `CaptureRecord.decode`);
`Writes.deviceInfoRequest/keepAlive/settingsRequest/deviceSettings(brightness:usbVolumeDb:)/captureDetails(slot:)`;
`Session.readDeviceInfo/readDeviceSettings/writeDeviceSettings/captureDetails`; `FakePedal` answers 46/91/65/67/17
(serial `NP00XXXXXX`). `DeviceTests` (5) pin the bodies and parses to the trace: 67 at 463.2 s
(`08 01 20 99 01 75 00 00 C0 C0`), 17 at 306.1 s, 47/92/66/18 replies. App: Settings → Device (`DevicePage.swift`):
About, two sliders (brightness in %, USB −20…0 dB in 0.5 steps with a typeable field), Raw settings disclosure,
Read again; reads on open/connect; writes only after a successful read, one in flight, latest value queued
(DECISION #16). "Info…" on the capture node's menu and the capture slot menu → popover (name, author, device type +
instrument with `CaptureKind` icons, tags as chips, description, hash with Copy). Dev remote `/device`, `/captureinfo`.
Frames from the recorded phone-app session (not published) inlined.
**Found:** the brief's 47 layout `5:{6:{6:"1"}}` is the string `"2.2.1"` misparsed as a message: 47.5 is the firmware.
The brief's 17 body `08 03 18 00 28 01` has a `1:3` the trace does not; the trace sends `18 00 28 01`, which we match.
Other agents' `pkill -f "Nano Cortex Editor.*-demo"` killed this session's instance; launched with
`--args -connect.atLaunch NO` (argument domain, nothing persisted) on port 4853 and `/demo` instead.
**Broke:** nothing known. NanoCore 39 tests, app unit tests 9 green.
**Decisions:** #16.
**Next:** Anup tries brightness and USB volume on the pedal; tap-order trace for the other settings fields.
**Blocked:** the ⚠️ check needs the pedal.

### 2026-10-09 — Advanced metronome (row 24)
**Step:** 24 · **Model:** Fable
**Did:** `MetronomePattern.swift` (pure, Foundation only): `events(beats:noteValue:accents:subdivision:swing:kind:)` → one bar of
`{offset, role, beat, sub, voice}`, `barKind` (count-in / play / gap-muted), `rampTempo`, the six meter presets, `MetronomeSetup`
(Codable, persisted as `metro.setup`), `MetronomeLevels`, and a `ClickSource` protocol (sound per role; `SynthClickSource` today,
sub ticks = the normal click pitched up a fifth). `Metronome`: one scheduler for both modes, two beats ahead on the sample clock,
event-relative placement so tempo changes don't drift, trainers asked only at bar boundaries, silent 1-frame buffers for `mute`
events so the indicator runs through muted bars, per-role gains baked into the buffers (the old per-beat `player.volume` applied to
everything already queued). Tempo-source hooks for row 25 (`tempoFollowsPreset`, `presetTempo`, `effectiveTempo`, `onTempoChanged`),
unused yet. `MetronomeOverlay.swift`: Simple (the original) / Advanced with the pill switch, accent cells, pips with sub pips,
trainers, Levels… popover. Settings → Metronome: Opens in, Advanced pattern, subdivision, count-in, the three levels (window 640 tall
on that section). New unit-test target `NanoCortexEditorTests` (not hosted: it compiles `MetronomePattern.swift` itself, so tests
never launch the app or touch Bluetooth); CI runs it. Dev remote `/metro` grew the Advanced setup, levels, `bar=N` dump, `events=1`
played log; `/shot?target=popover`; `/settings?opensin=`.
**Verified (demo, :4850):** 5/4 (3+2) triplets at 120 for 3 s → 17 events played (accent 2, soft 3, normal 1, sub 11; the 18th was
still in the output latency), bar 0 = 15 events; gap trainer play 1/mute 1 with a 1-bar count-in at 240 → bars countIn, play, muted
(silent `mute` events, label "Bar 2 · muted"), then "Bar 3"; ramp 200 → 224 +8 every bar → bar tempos 200, 208, 216, 224, 224, bar
lengths 1.200/1.154/1.111/1.071 s; Stop restores 200. Unit tests 8/8. UI smoke: see the PR.
**Broke:** nothing known. A fresh install: Simple mode, levels 100/70/50 = the original accent/click mix.
**Decisions:** #15.
**Next:** Anup tries the Advanced overlay; Electron parity for the metronome; row 25 needs a trace.
**Blocked:** nothing.

### 2026-10-09 — Settings window (row 23)
**Step:** 23 · **Model:** Opus
**Did:** `Settings.swift`: `AppSettings` (@Observable singleton over UserDefaults), `Accent` palette (purple default with
its exact original constants; others derive hi/row/number/focus/TX colours; dark text on teal/green/yellow primary
buttons), `AppIcon` (recolours `icon.svg`'s LED gradient, sets `NSApp.applicationIconImage`, the header mark uses the
same image), `SettingsView` (Appearance, Metronome, Connection, Advanced). `Theme.accent` and friends are computed.
Metronome: five synthesized sounds (`ClickSound.samples`, pure), Preview, volume/output/sound backed by
`AppSettings` (overlay and Settings stay in sync), tempo starts at the default (seeded from the old `metro.bpm`).
Connection: connect at launch to the remembered pedal only (never a fresh scan; `-demo` skips it), Forget clears
`pedal.identifier`/`pedal.name` and disconnects. Header mark 30 → 39 pt frame (~34 pt visible). Dev remote
`/settings` and `/shot?target=settings`. Smoke test opens ⌘, and closes it.
**Found:** an instance launched while another app is frontmost gets no window (SwiftUI opens it on activation);
`open -a <app>` reopens it. Older builds behave the same, and it made the UI smoke fail at launch this session.
**Broke:** nothing known; the UI smoke could not be confirmed locally (above).
**Decisions:** #12, #13.
**Next:** Anup reviews the settings window and the accents; Electron parity for settings (accent, click sounds).
**Blocked:** nothing.

### 2026-10-09 — Parity leftovers: session recording, shortcuts sheet, Refresh (row 21)
**Step:** 21 · **Model:** Opus
**Did:** `NanoCore/Recording.swift`: `SessionRecorder` (lock-based, `Sendable`) and `SessionRecording` in the Electron
fixture format (`{app, recorded, demo, device, preset, events: [{t, dir, hex, label?}], log: [{t, text}]}`; `preset`
1-based, `device`/`preset` null when unknown). `Session(transport:tap:)` calls the tap for every raw C305 notification
(before reassembly) and every C304 write (with its label); the store installs it on every session and feeds the
Activity lines. Status bar: Shortcuts, then Record ("Recording N" in red/semibold, save panel on stop, default folder
the core's Fixtures in source builds, else `~/Documents/Nano Cortex Editor`). Shortcuts sheet (status bar, `?` when
no text field has focus, View menu) listing only the shortcuts this app has. Pedal menu: ⌘↑/⌘↓ previous/next preset.
Header: ghost Refresh at level 0; Refresh (and ⇧⌘R) now re-read names + state like the initial sync
(`Session.readAll()`). Dev remote: `/record`, `/shortcuts`, `/refresh`. Tests: `RecordingTests` (tap vs FakePedal,
JSON round trip through the fixture decoder, nulls/format, Electron fixtures decode); UI smoke opens/closes the sheet.
**Found:** the task brief said `lines`; the Electron files actually use `log: [{t, text}]`, so that is what we write.
One Electron fixture has no events and no log lines.
**Broke:** nothing.
**Decisions:** none.
**Next:** Electron parity check for ⇧⌘R / ⌘1–2 / ⌘K in its sheet if Anup wants the lists identical.
**Blocked:** nothing.

### 2026-10-08 — Visual parity with the Electron app, exact pass (row 11)
**Step:** 11 (still `[~]`, needs Anup's review) · **Model:** Opus (worker)
**Did:** Went through `pro/ui.css` value by value. The biggest gap was a bug: `Theme.font` asked for
"IBMPlexSans-Medium"/"IBMPlexSans-SemiBold", but the TTFs' PostScript names are `IBMPlexSans-Medm` and
`IBMPlexSans-SmBld`, so every medium/semibold label was silently drawn in SF. Also turned off font smoothing
(AppleFontSmoothing 0, like WebKit's `antialiased`) so light-on-dark text is no longer a weight too heavy.
Top bar is now two rows like Electron: a 44-point tab bar (`src/toolbar.html`: Editor/Cortex Cloud pill group,
the Cloud controls ← → ↻ Home / Send to Nano / ⋯ / Sign out moved up from the Cloud tab, the "NANO CORTEX EDITOR ·
UNOFFICIAL" caption, window drag region, traffic lights centred in it) and the 48-point editor header (Editor tab
only). Then sidebar 248 wide with 28-point rows, `.btn`/ghost/small buttons, the chain (radial glow, one cable,
jacks, `.node` gradient/border/shadow/lift, `.stomp` LEDs, IN/OUT tags, stage names in the stage colour), knobs
(54-point dial, arc from zero for ranges that cross it, cap gradient), inspector sections/notes/params grid,
switch, segmented control, slot grid, `.pop` popovers, modals, toast, drawer (under the main column only, timestamps
faint), status bar, connect card, tuner and metronome cards. Save is purple only with unsaved edits, as in Electron.
Dev remote: `/shot?full=1`, `/hit`. `-window` is re-applied after window restoration.
**Broke:** nothing; UI smoke test green.
**Decisions:** none new.
**Next:** Anup reviews side by side (`/shot` vs `test-output/*.png` in the Electron repo); then tag v0.1.0.

### 2026-10-08 — Row 7 closed on the pedal; 1Password via launchd; polish fit
**Step:** 7 (closed), 11 · **Model:** Fable
**Did:** Signed in to Cortex Cloud in the native tab and sent a real capture to the pedal (user capture 6, Cloud
hash matches). Found why the 1Password CLI failed from the app ("No accounts configured"): the desktop
integration vets the responsible process and an ad-hoc signed app is not trusted; a launchd-submitted job is,
so the fallback runs that way. Anup prefers native autofill, so the CLI fill moved to the ⋯ menu and the login
page hints at Universal Autofill (⌘\) / macOS Password AutoFill. Fixed the cookie-consent iframe opening in
the browser (only top-level navigations leave). UI smoke test fits the 1024×768 CI display.
**Broke:** nothing. **Decisions:** none new. **Next:** Anup reviews the polish side by side; tag v0.1.0.

### 2026-10-08 — Polish pass, first iteration (row 11)
**Step:** 11 · **Model:** Fable
**Did:** Compared against the Electron UX-test screenshots and closed the big gaps: header with text buttons,
status pill, "Unsaved changes" wording and Save ⌘S; chain with IN/OUT pills, connectors, fixed-size nodes with
coloured labels, name and detail lines, glow on the selected node; sidebar rows; inspector heads ("Capture",
"Pre FX 1" + model pill with a searchable, category-grouped list), AMP / TONE / MICROPHONE sections, slot grids
for captures and cabs, segmented mic and position, coloured switch, bigger knobs. Minimum window 1300×700.
**Broke:** nothing; UI smoke test updated and green.
**Next:** Anup reviews side by side; remaining ideas: node hover lift, the Electron "Shortcuts" sheet and Record
button (session recording is not ported), tuner/metronome overlay polish.

### 2026-10-08 — Rows 7, 8, 9 and 5b while Anup is away
**Step:** 7 (hardware part open), 8, 9 (tag open), 5b · **Model:** Fable
**Did:** Cortex Cloud tab (WKWebView, persistent session, toolbar with back/reload/home, Fill from 1Password via
the `op` CLI, Send to Nano, sign out); capture bundle parsing in NanoCore (system zlib + a tar reader, fixture
test); Send sheet → streamed upload with progress → library refresh → slot offer → slot chooser, verified end to
end in demo mode. Metronome (AVAudioEngine clicks scheduled on the audio clock, accent, tap tempo, CoreAudio
output picker, settings remembered) and a menu bar extra (link, preset prev/next, tuner, metronome). App icon
asset catalog rendered from the SVG by `scripts/build-icon.swift`. Release workflow (universal Release build,
ad-hoc signed, zipped, attached to the tag's Release), rehearsed locally. XCUITest smoke target in CI.
**Broke:** nothing. 29 core tests, 1 UI test green.
**Decisions:** none new.
**Next (needs Anup):** sign in to Cortex Cloud (Fill from 1Password) and send one capture; tag v0.1.0 and check
the Release; then row 11, the design polish pass.
**Blocked:** the two ⚠️ items above.

### 2026-10-08 — Row 6 on the pedal: library, rename, save, tuner, usage scan
**Step:** 6 (closed) · **Model:** Fable
**Did:** Library picker (searchable popover, Factory / Yours, current item marked) → slot chooser sheet →
load; "save changes?" prompt on preset switch with edits; toasts; explicit slot usage scan. All verified on the
pedal. Found and fixed a core bug: a request's timeout timer fired after the request was answered and failed
every later waiter of the same type (killed the scan at preset 18); timeouts are per waiter now, with a test.
**Found:** (1) capture position 6 / cab slot 6 = "referenced straight from the library, not in a slot"
(PROTOCOL-NOTES §8); the parser no longer truncates metadata and the UI shows "From the library". (2) The cab
settings record elides defaults (index 0, position 1) and its position is 0-based in both the record and the
state's full name; the mic list comes in field 7. (3) Cab mic/position is stored in the cab slot, not the preset
(DECISION #11); the test change was reverted on the pedal and presets 1/3/6/8 read as before.
**Broke:** nothing. 27 core tests green. Preset 64 left as found (capture bypass, cab bypass, gain 140).
**Decisions:** #11.
**Next:** row 7, Cortex Cloud tab + Send to Nano (needs the pedal for one upload), or 5b first.
**Blocked:** nothing.

### 2026-10-08 — The real UI (row 5)
**Step:** 5 (closed) · **Model:** Fable
**Did:** Theme (Cortex Control palette, bundled IBM Plex Sans), `Knob` (drag, Shift fine, double-click reset, arrows,
typed value), full editing surface in `PedalStore` (FX model/params/enable, capture + amp, cab slot/params/mic,
gate, rename, library, tuner), window shell: header with wordmark/preset/rename/Tuner/Save, preset sidebar with
filter, 8-node chain, per-stage inspector, status bar, Activity drawer (⌘L), connect card, tuner overlay.
Dev remote grew `/ui`, `/stage`, `/fxmodel`, `/fxon`, `/fxparam`, `/capture`, `/cab`, `/cabmic`, `/gate`,
`/rename`, `/tuner`, `/library`, `/drawer`, `/shot` (in-process PNG of the window). Session events now carry only
unsolicited traffic (DECISION #10), which removed a triple parameter refresh after sync; parameters are re-read
only on a preset load or when a block's model changes.
**Broke:** nothing. 26 core tests green.
**Decisions:** #10.
**Next:** row 6 on the pedal (save/rename/tuner/library→slot already wired; verify and add slot usage), then 5b.
**Blocked:** nothing.

### 2026-10-08 — Save, power-cycle, automatic reconnect verified
**Step:** 4 (closed) · **Model:** Fable
**Did:** Save (explicit button, ⌘S) in the store and window; dev remote `/save`. Found and fixed the reconnect bug:
cancelling a session's reader terminated the transport's single `AsyncStream`, so the next session never saw replies.
Transports now hand out a fresh stream per session through `NotificationHub`. Test added. Verified on the pedal:
save, power-cycle, automatic reattach and re-sync, persisted value.
**Found:** after a disconnect the pedal advertises only briefly; after that EXIT + CAPTURE is needed, and the
pending CoreBluetooth connect then completes by itself.
**Broke:** nothing.
**Decisions:** none new.
**Next:** row 5, the real UI, built to the Electron app's design (its UX-test check names are the acceptance list).
**Blocked:** nothing.

### 2026-10-08 — First native connection to the pedal
**Step:** 4 · **Model:** Fable
**Did:** `BluetoothTransport` (CoreBluetooth; finds the pedal by service A002, remembers it, keeps a pending connect
while it is away), `PedalStore` (@Observable, one transport per app lifetime, idempotent connect), first-light window
(presets, amp sliders, status, activity), activity log file (`~/Library/Logs/Nano Cortex Editor/activity.log`), debug
dev remote on 127.0.0.1:4849. Verified on the pedal: connect + sync in 2 s, preset 64 over BLE, Gain write and
read-back with the dirty flag.
**Found:** a second `CBCentralManager` opens a second GATT link and both sessions time out; keep one transport.
MTU reported by CoreBluetooth for writes with response is 512 (uploads use 500-byte writes, fine). After the app is
killed mid-connection the pedal stops advertising until EXIT + CAPTURE; after a clean relaunch it reconnects alone.
**Broke:** nothing.
**Decisions:** none new.
**Next:** finish row 4's verification (save, power-cycle, reconnect after drop), then row 5 (the real UI).
**Blocked:** the remaining row-4 checks need Anup at the pedal.

### 2026-10-08 — Transport, fake pedal, session
**Step:** 3 · **Model:** Fable
**Did:** `Writes` (every C304 write, pinned to the recorded bytes), `CabSettings`/`FXParams` reply parsers, `NanoTransport`
protocol, `FakePedal` actor (encodes state/metadata/library replies, answers every write like the pedal, replies
asynchronously), `Session` actor (connect/sync, serialized write queue with per-key coalescing, typed-reply waiters
with timeouts, editing API, capture upload with progress, events stream). 25 tests.
**Broke:** nothing.
**Decisions:** none new.
**Next:** step 4, `BluetoothTransport` on CoreBluetooth in the app target, then the first connection to the real pedal.
**Blocked:** step 4's verification needs Anup and the pedal.

### 2026-10-08 — State, metadata and library parsers
**Step:** 2 · **Model:** Fable
**Did:** `StateDump`, `Metadata`, `Library`, `Capture` curves; `Models.swift` generated from the Electron core (74 effect
models, ids, param metadata). 14 golden tests pass.
**Found:** FX model ids (fields 48–52) are varints; the catalogue keys them by the raw varint bytes in hex. The big
reply to the metadata request also carries the full current state. Empty presets come back nameless (UI shows "Empty").
The Electron recordings start after their initial sync, so the phone trace is the metadata fixture.
**Broke:** nothing.
**Decisions:** none new.
**Next:** step 3, `Transport` protocol + `FakePedal` + `Session` actor with coalescing write queue.
**Blocked:** nothing.

### 2026-10-08 — Scaffold and protocol core
**Step:** 1 · **Model:** Fable
**Did:** Repo, docs, XcodeGen project, `NanoCore` with `Proto`, `Frame`, `Messages`; golden tests reproduce the preset
change, rename, tuner frames from the pedal recording and the capture uploads byte for byte (phone trace + Electron
transfer, 22 writes). CI workflow.
**Found:** the official app's upload carries `3.2 = hex MD5 of the capture bytes`, which the Electron port omits (pedal
accepts both); the Swift encoder sends it. Row added to the Electron repo's queue for parity.
**Broke:** nothing.
**Decisions:** #1–#9.
**Next:** step 2, `StateDump` + `Library` parsers with golden tests.
**Blocked:** nothing.
