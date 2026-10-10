# Nano Cortex Editor (native macOS)

Native Swift/SwiftUI editor for the Neural DSP Nano Cortex. Unofficial; private repo. The Electron app in
`../nano-cortex-desktop` is the reference implementation: same protocol, verified on the pedal, and the source of every
fixture here.

## Read in this order
1. `VISION.md` — what and why
2. `PLAN.md` — the session log at the bottom first, then the step it points at
3. `DECISIONS.md` — stable IDs; cite them in code where something looks wrong but is right
4. `docs/PROTOCOL-NOTES.md` — the decoded protocol (copied from the Electron repo's investigation)

## Rules an agent breaks by accident
- `NanoCore` has no UI and no CoreBluetooth import; keep it headless and tested against `Tests/.../Fixtures`.
- Never commit raw `.pklg`/HCI traces (device addresses, pedal serial). Fixtures are scrubbed JSON only.
- Edits are live on the pedal; **Save** commits. Never save, rename, or load into a slot without an explicit user action.
- Before any new write to the real pedal, check the Electron recordings for the same bytes; if there are none, record first.
- The `.xcodeproj` is generated: edit `project.yml`, run `xcodegen generate`.
- No Neural DSP logos; keep the trademark note.

## How we work here
- One step per session; end by ticking `PLAN.md`, appending the session log, updating `DECISIONS.md`, committing on
  `feature/*`, PR to `staging`; `staging` → `main` by PR. Hooks refuse direct pushes.
- Model per step is in `PLAN.md` §6 (model-handoff skill).
- Hardware in the loop: Anup has the pedal; steps marked ⚠️ need him.

## Backlog
`BACKLOG.md` here is the shared soft idea list for both editors (not a plan; see the Backlog section of the global
CLAUDE.md). Ask at task boundaries whether Anup wants to pick something from it.

## Feature parity
Every feature Anup asks for lands in both this app and the Electron one (`../nano-cortex-desktop`) unless it genuinely cannot apply to one; he is still deciding between them. The Electron app's `pro/ui.css` is the visual reference: match its sizes, spacing and colours.

## Hardware sessions
Debug builds expose a dev remote on `http://127.0.0.1:4849` and append the Activity log to
`~/Library/Logs/Nano Cortex Editor/activity.log` (`tail -f` it). Release builds have neither. Endpoints:
- Link: `/connect`, `/disconnect`, `/demo`, `/state` (parsed state dump + metadata), `/ui` (store view: blocks, cab, tab, sheets), `/log?since=N`, `/reread`, `/save`
- Edits: `/preset?i=` (0-based; with edits it opens the prompt, answer with `/switch?choice=save|discard|cancel`), `/amp?knob=&v=`, `/fxmodel?slot=&name=`, `/fxon?slot=&on=`, `/fxparam?slot=&i=&v=`, `/capture?slot=`, `/cab?slot=`, `/cabmic?mic=&pos=`, `/cabrefresh`, `/gate?on=&r=`, `/rename?name=`, `/tuner?on=`, `/footswitch?slot=ia|ib|iia|iib&i=` (assign; with unsaved edits it opens the save prompt: add `confirm=save|discard|cancel` or answer with `/switch?choice=`; `open=1` opens the Assign… popover)
- Library: `/library` (names plus `kinds`: `type|instrument` per capture; `open=capture|cab` opens the picker), `/pick?kind=capture|cab&factory=1|0&index=&slot=&name=`, `/chooser?...` (opens the slot sheet), `/scan` (slot usage, switches through every preset)
- Cloud: `/tab?t=cloud|editor`, `/cloud?url=`, `/send?id=` (capture page → Send sheet), `/sendfile?file=` (saved download JSON, demo), `/sendconfirm`, `/offer?choice=slot|later`
- Recording: `/record?on=1` starts, `/record?on=0&file=path` stops and writes the JSON without the save panel (no `file`: the default folder), `/record` reports `{recording, events}`
- Sheets: `/shortcuts?on=1|0`, `/refresh` (re-read names + state)
- Metronome: `/metro?open=&on=&bpm=&beats=&tap=1&wait=ms&mode=simple|advanced&levels=0|1` (popover); Advanced setup `abeats=&nv=&pattern=5/4&accents=ASSNS&sub=1..4&swing=0..100&countin=0..2&ramp=0|1&target=&step=&every=&gap=0|1&play=&mute=`; levels `lacc=&lmain=&lsub=` (0..100); `type=metro-beats|ramp-target|ramp-step|ramp-every|gap-play|gap-mute|metro-simple-beats&text=` commits a typed string like the stepper field (clamped; no number = unchanged), `focus=<stepper id>` puts the cursor in that field (also `settings-beats`); `bar=N` dumps bar N's generated events, `events=1` summarises what played since Start (`&list=1` every event). It writes the shared `metro.setup`/`metro.level*` defaults: delete them afterwards
- Device: `/device` (reads on first use; dump of About, brightness, USB dB, raw 66 fields), `/device?brightness=0..255|pct=0..100&usb=dB&read=1` (live writes, need a prior read); `/captureinfo?slot=N` (17/18 details as JSON; `open=1` opens the Info popover on that slot's cell, `anchor=node` on the capture node)
- Keys: `/key?k=esc|return|space|tab` or `/key?chars=text` (`&target=settings`) dispatches keys in-process like NSApplication (key equivalents first, then the first responder); works while the window is not key
- Other: `/drawer?on=`, `/stage?s=`, `/shot?file=` (window PNG; `&full=1` includes the title bar and traffic lights, `&target=cloud` the web view, `&target=popover` an open popover), `/resize?w=&h=`, `/hit?x=&y=` (which view takes a click at that window point)
- Settings: `/settings` dumps them (plus the app menu's items and the window list); set with `accent=purple|teal|green|orange|yellow|red|blue`, `dock=0|1`, `sound=click|woodblock|tick|beep|cowbell`, `volume=`, `bpm=`/`beats=` (defaults), `connect=0|1`, `showlog=0|1`, `opensin=simple|advanced`, `section=appearance|metronome|connection|device|advanced`, `open=1` (opens the window), `preview=1`, `forget=1` (clears the remembered pedal: shared UserDefaults, so restore `pedal.identifier` afterwards), `icon=/path.png` (writes the 1024 px recoloured icon), `sounds=1` (synth buffer stats); `/shot?target=settings&full=1&file=` screenshots the Settings window
Launch arguments: `-demo` connects to the fake pedal on launch, `-no-dev-remote` skips the listener (the UI tests use both).
A second instance next to Anup's (never kill his): `open -n --env NANO_DEV_PORT=4850 "build/Build/Products/Debug/Nano Cortex Editor.app" --args -demo`, then `/demo`. Wait until the previous demo instance has exited before relaunching (the port stays bound otherwise), and size the window with `/resize?w=&h=` rather than `-window WxH`: with `-window` the dev remote sometimes never comes up (seen 2026-10-09).
Without `-demo`, the app connects at launch to the remembered pedal when Settings → Connection allows it (default on).
A second instance shares the owner's UserDefaults (same bundle id): put back any setting you change.
If a launched instance answers nothing on its port, it has no window yet (macOS did not let it activate while
another app was in front): `open -a "<path>/Nano Cortex Editor.app"` sends a reopen and the window appears.

## Commands
```bash
swift test --package-path NanoCore          # protocol core, headless
xcodebuild -project NanoCortexEditor.xcodeproj -scheme NanoCortexEditor -destination 'platform=macOS' -only-testing:NanoCortexEditorTests test   # app unit tests (metronome pattern), no app launch
xcodebuild -project NanoCortexEditor.xcodeproj -scheme NanoCortexEditor -destination 'platform=macOS' -only-testing:NanoCortexEditorUITests test   # demo-mode UI smoke
swift scripts/build-icon.swift              # App/Resources/icon.svg → AppIcon asset catalog
xcodegen generate                           # writes NanoCortexEditor.xcodeproj
xcodebuild -project NanoCortexEditor.xcodeproj -scheme NanoCortexEditor -configuration Debug -destination 'platform=macOS' build
open NanoCortexEditor.xcodeproj             # work in Xcode
```
`ELECTRON_RUN_AS_NODE=1` is set in VS Code's terminal; it is harmless here but `env -u ELECTRON_RUN_AS_NODE` keeps
`swift` invocations clean of surprises when scripts spawn tools.
