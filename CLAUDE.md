# Nano Cortex Editor (native macOS)

Native Swift/SwiftUI editor for the Neural DSP Nano Cortex. Unofficial. Repo: `AJs-Creations/nano-cortex-editor-mac`
(MIT; user docs in `README.md` and `docs/MANUAL.md`, release notes in `CHANGELOG.md`). The sibling cross-platform
Electron edition is `AJs-Creations/nano-cortex-editor` (local clone `../nano-cortex-editor`): same protocol, verified on
the pedal first. Earlier history lives in the private archive repos (`nano-cortex-mac`, `nano-cortex-desktop`).

## Read in this order
1. `VISION.md` — what and why
2. `PLAN.md` — the session log at the bottom first, then the step it points at
3. `DECISIONS.md` — stable IDs; cite them in code where something looks wrong but is right
4. `docs/PROTOCOL-NOTES.md` — the decoded protocol (copied from the Electron repo's investigation)

## Rules an agent breaks by accident
- `NanoCore` has no UI and no CoreBluetooth import; keep it headless and tested.
- **Never commit recordings**: session recordings, phone-app traces, `.pklg`/HCI captures, capture files, screenshots of
  real sessions (pedal serials, device ids, users' presets). Tests inline only the frames they assert, scrubbed, in
  `NanoCore/Tests/NanoCoreTests/RecordedFrames.swift`, or generate data with `FakePedal`/`StateEncoder` (DECISIONS #19).
  Debug builds save recordings into the git-ignored `recordings/`.
- Never screenshot the Cortex Cloud website for docs (their pages, artwork, users' content).
- Edits are live on the pedal; **Save** commits. Never save, rename, or load into a slot without an explicit user action.
- Before any new write to the real pedal, check the Electron recordings for the same bytes; if there are none, record first.
- The `.xcodeproj` is generated: edit `project.yml`, run `xcodegen generate`.
- No Neural DSP logos; keep the trademark note.

## Firmware updates
The effect list is hardcoded: `NanoCore/Sources/NanoCore/Models.swift` (model ids and parameters, from firmware 2.2.1).
The tested version is one constant, `Compatibility.testedFirmware` in `NanoCore/Sources/NanoCore/Compatibility.swift`.
A newer firmware gets a one-time banner per version (`ui.firmwareWarned`; in memory only in demo mode), and a model id
we don't list shows as "Unknown effect" (on/off and replacing it only; no parameter writes or refreshes).
Demo hooks: `-demo.firmware 2.3.0`, `-demo.unknownFX post2=7E`, `/demo?firmware=`, `/fxunknown?slot=&id=`, `/firmwarenotice`.
After Neural DSP ships a firmware update:
1. Read the release notes for new or changed effects.
2. Trace the new effects in the official app (record their model select and parameter writes; ⚠️ needs the pedal).
3. Add the ids and parameters to `Models.swift` (both editors), with a recorded-frame test.
4. Bump `Compatibility.testedFirmware` once the update is verified on the pedal.

## How we work here
- One step per session; end by ticking `PLAN.md`, appending the session log, updating `DECISIONS.md`, committing on
  `feature/*`, PR to `staging`; `staging` → `main` by PR. Hooks refuse direct pushes.
- Releases: `v*` tag on `main` → `release.yml` (universal `Nano-Cortex-Editor-mac-<v>-universal.zip`, Developer ID
  signed and notarised, notes from `CHANGELOG.md`). Bump `MARKETING_VERSION` in `project.yml` and add the CHANGELOG
  section first. Never write a Finder custom icon into the bundle (breaks the signature).
- **One version for both editions, always current.** This edition and the Electron one release together under the
  same version (1.2.0 was the first shared one). Settings shows it, so bump it in both repos in the same round, before
  tagging: here `MARKETING_VERSION` in `project.yml`, there `package.json` (and `package-lock.json`) plus
  `pro/links.js`. `release.yml` refuses a tag that differs from `project.yml`.
- Signing (DECISIONS #22): only `release.yml` signs. The Actions secret `OP_SERVICE_ACCOUNT_TOKEN` is a 1Password
  service account that reads only the vault **`Apple Signing`**: item `Apple Developer ID` (the
  `developer-id-application.p12`, field `password`, team `272K9YT73Z`) and item `App Store Connect API Key` (the
  `.p8`, fields `key id`, `issuer id`). The job imports the .p12 into a temporary keychain, builds with
  `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application"`, hardened runtime and `--timestamp`,
  submits with `notarytool` (API key), staples, checks `spctl` says `source=Notarized Developer ID`, then deletes the
  keychain and files. No entitlements file (none needed; justify any you add). `project.yml`, `ci.yml` and local
  builds stay ad-hoc (`-`) and need no credentials. Manual run: `gh workflow run release.yml --ref <branch>` builds
  only (zip and `appcast.xml` as a workflow artifact); `-f release_tag=vX.Y.Z` builds that tag and replaces the zip
  and `appcast.xml` on the existing Release (never creates one or moves a tag).
- Updates (DECISIONS #23): Sparkle 2 (SPM, `exactVersion` in `project.yml`). `SparkleUpdater.swift` starts the
  standard updater controller at launch; `Updates.swift` (pure, unit-tested) holds the feed URL, the launch-check
  rule and the `Updates` model the app menu's "Check for Updates…" and Settings → Advanced bind to. Info.plist keys in
  `project.yml`: `SUFeedURL` (= `UpdateFeed.url`, a test keeps them equal), `SUPublicEDKey`, `SUEnableAutomaticChecks`
  (on, no permission prompt), `SUScheduledCheckInterval` (a day), `SUAutomaticallyUpdate` (off); plus a background
  check 5 s after launch. With `-demo` the updater is never started (UI tests, screenshots and agent sessions get no
  check and no Sparkle window; "Check for Updates…" is greyed out). UI tests also pass `-ApplePersistenceIgnoreState
  YES`: a killed launch's saved window state made the next launch open with no window. Checks, results and the user's choice
  go to the Activity log as `Updates: …`.
  - The feed is the `appcast.xml` asset of the latest non-prerelease Release (`releases/latest/download/appcast.xml`).
    `release.yml` re-signs Sparkle's helpers (Installer.xpc, Downloader.xpc, Autoupdate, Updater.app, the framework,
    then the app) with the Developer ID, checks each signature, launches the signed app once, then runs
    `generate_appcast` with the EdDSA key from 1Password (`Apple Signing` → "Sparkle Update Signing Key", field
    `private key`; also in Anup's login Keychain, `generate_keys --account nano-cortex-editor-mac`) and
    `scripts/verify-appcast.swift` against the app's public key. The CHANGELOG section of the version becomes the
    update alert's notes, so write it for users.
  - Sparkle compares `CFBundleVersion` (the release run number), not the marketing version: never rename
    `release.yml`, and a local test pair needs both versions bumped (`MARKETING_VERSION=… CURRENT_PROJECT_VERSION=…`).
  - Test locally against your own feed: `generate_appcast --ed-key-file <key> --download-url-prefix
    http://127.0.0.1:<port>/ <dir>`, serve `<dir>`, and launch the older build with
    `--args -SUFeedURL http://127.0.0.1:<port>/appcast.xml -connect.atLaunch NO` (argument domain: nothing is
    written). Export the key with `generate_keys --account nano-cortex-editor-mac -x <file>` into a 0700 temp dir and
    delete it after. Use **Debug** builds: an ad-hoc Release build crashes at launch (library validation with the
    hardened runtime refuses the ad-hoc Sparkle.framework). Background-found updates wait until the app is active.
    Sparkle relaunches without your arguments, so set `connect.atLaunch` NO in the shared defaults first (and delete
    it after), or the relaunched build connects to the remembered pedal. Afterwards delete the `SU*` keys and the
    window-frame keys your runs added (diff a `defaults export` taken before), and only the files your runs created
    (check birth times with `stat -f %SB`): typically `~/Library/Caches/com.community.nanocortex/{Cache.db*,
    fsCachedData,org.sparkle-project.Sparkle}`, `~/Library/HTTPStorages/com.community.nanocortex*` and
    `~/Library/Caches/Sparkle_generate_appcast`. Two processes share the name "Nano Cortex Editor": drive yours by
    PID (AX API), never by app name.
- Model per step is in `PLAN.md` §6 (model-handoff skill).
- Hardware in the loop: Anup has the pedal; steps marked ⚠️ need him.

## Backlog
`BACKLOG.md` here is the shared soft idea list for both editors (not a plan; see the Backlog section of the global
CLAUDE.md). Ask at task boundaries whether Anup wants to pick something from it.

## Feature parity
Every feature Anup asks for lands in both this app and the Electron one (`../nano-cortex-editor`) unless it genuinely cannot apply to one; he is still deciding between them. The Electron app's `pro/ui.css` is the visual reference: match its sizes, spacing and colours.

## Hardware sessions
Debug builds expose a dev remote on `http://127.0.0.1:4849` (Release builds don't). It listens on loopback only
(`lsof -nP -iTCP:<port> -sTCP:LISTEN` shows `127.0.0.1:<port>`, never `*:<port>`) and refuses, with a 403 and
`{"ok":false,"error":"browser requests are refused"}`, any request that carries `Origin` or a `Sec-Fetch-Site` /
`-Mode` / `-Dest` header or whose `Host` is not exactly `127.0.0.1:<port>` or `localhost:<port>` (a web page can make a
browser call a localhost port; curl and scripts send none of these). `DevRemoteRequest.swift` holds the rule and reads
the whole request head, not just the first packet (DECISIONS #34). Every build appends the Activity
log to `~/Library/Logs/Nano Cortex Editor/activity.log` (`tail -f` it), whatever the Developer tools switch says; it
rotates to `activity.1.log` past ~2 MB (`RotatingLogFile`, DECISIONS #21). Record, Activity, ⌘L, hashes, raw device
fields and the "Sent: …" status text only show with Settings → Advanced → **Developer tools** on (`ui.devTools`, off by
default; `-ui.devTools YES` turns it on for one launch without writing it). The dev remote works either way (`/drawer`
and `/record` too). Endpoints:
- Link: `/connect`, `/disconnect`, `/demo`, `/state` (parsed state dump + metadata), `/ui` (store view: blocks, cab, tab, sheets), `/log?since=N`, `/reread`, `/save`, `/quit` (quits this instance like ⌘Q, 0.3 s after replying: an audition that plays is stopped first, at most 1.5 s, one `Quit: …` Activity line; DECISIONS #38)
- Edits: `/preset?i=` (0-based; with edits it opens the prompt, answer with `/switch?choice=save|discard|cancel`), `/amp?knob=&v=`, `/fxmodel?slot=&name=`, `/fxon?slot=&on=`, `/fxparam?slot=&i=&v=`, `/capture?slot=`, `/cab?slot=`, `/cabmic?mic=&pos=`, `/cabrefresh`, `/gate?on=&r=`, `/rename?name=`, `/tuner?on=`, `/footswitch?slot=ia|ib|iia|iib&i=` (assign; with unsaved edits it opens the save prompt: add `confirm=save|discard|cancel` or answer with `/switch?choice=`; `open=1` opens the Assign… popover)
- Library: `/library` (names plus `kinds`: `type|instrument` per capture; `open=capture|cab` opens the picker), `/pick?kind=capture|cab&factory=1|0&index=&slot=&name=`, `/chooser?...` (opens the slot sheet), `/scan` (slot usage, switches through every preset)
- Cloud: `/tab?t=cloud|editor`, `/cloud?url=`, `/send?id=` (capture page → Send sheet), `/sendfile?file=` (saved download JSON, demo), `/sendconfirm`, `/offer?choice=slot|later`
- Auditions, Cloud IRs (`AuditionRemote.swift`): `/audition` (state; `ir=<name>&kind=factory|user` ▶, `stop=1` ■, `keepalive=1`,
  `interval=s`, `gate=<action>`; demo: `refuse=1|0` the pedal refuses every stop, `delay=ms` slow replies, `pedalpreset=N` a
  footswitch preset change), `/preview?file=<capture download json>|id=<uuid>` (Live Preview; `stop=1`), `/cloudir?file=<wav>&name=&id=`
  (a downloaded Cloud IR; `confirm=send|cancel`, or answer later with `choice=`; `status=1`), `/irdelete?index=&name=` (the
  confirmation; `confirm=1` deletes), `/irtoggle` (IR: On / Off), `/toolbarshot?file=` (the tab bar only, never a Cloud page)
- Recording: `/record?on=1` starts, `/record?on=0&file=path` stops and writes the JSON without the save panel (no `file`: the default folder), `/record` reports `{recording, events}`
- Sheets: `/shortcuts?on=1|0`, `/refresh` (re-read names + state)
- Metronome: `/metro?open=&on=&bpm=&beats=&tap=1&wait=ms&mode=simple|advanced&levels=0|1` (popover); Advanced setup `abeats=&nv=&pattern=5/4&accents=ASSNS&sub=1..4&swing=0..100&countin=0..2&ramp=0|1&target=&step=&every=&gap=0|1&play=&mute=`; levels `lacc=&lmain=&lsub=` (0..100); `type=metro-beats|ramp-target|ramp-step|ramp-every|gap-play|gap-mute|metro-simple-beats&text=` commits a typed string like the stepper field (clamped; no number = unchanged), `focus=<stepper id>` puts the cursor in that field (also `settings-beats`); `bar=N` dumps bar N's generated events, `events=1` summarises what played since Start (`&list=1` every event; `sounds` counts role:sound pairs such as `normal:sample`, `cut` the sounds cut at the next event). Sounds: `sample=accent|main|sub&file=<abs path>` picks a sample as the open panel would (checked, copied to `~/Library/Application Support/com.community.nanocortex/Metronome Sounds/<role>.<ext>`; before 1.2.1 it was `…/Nano Cortex Editor/Metronome Sounds`, the Electron edition's data folder, and launch moves it once, DECISIONS #36), `&reset=1` back to the built-in sound, `&builtin=click|…` that row's built-in sound, `&preview=1` its ▶; every reply has `sounds` per role (`/settings?sound=` sets all three rows). It writes the shared `metro.setup`/`metro.level*`/`metro.sounds` defaults: delete them afterwards, and the copies (and that folder if you created it)
- Device: `/device` (reads on first use; dump of About, brightness, USB dB, raw 66 fields), `/device?brightness=0..255|pct=0..100&usb=dB&read=1` (live writes, need a prior read); `/captureinfo?slot=N` (17/18 details as JSON, with `cloudId`/`cloudURL` when the description is a bare Cortex Cloud ID; `open=1` opens the Info popover on that slot's cell, `anchor=node` on the capture node; `open=1&press=cloud` then presses "Open in Cortex Cloud": Cloud tab, that page; the demo pedal's slot 5 has an ID, as in the Electron demo)
- Keys: `/key?k=esc|return|space|tab` or `/key?chars=text` (`&target=settings`) dispatches keys in-process like NSApplication (key equivalents first, then the first responder); works while the window is not key
- Other: `/drawer?on=`, `/stage?s=`, `/shot?file=` (window PNG; `&full=1` includes the title bar and traffic lights, `&target=cloud` the web view, `&target=popover` an open popover), `/resize?w=&h=`, `/hit?x=&y=` (which view takes a click at that window point)
- Links: `/support` reports the URL the status bar's ♥ Support button opens (without opening a browser), the other outbound links (`Links.swift`), the Help menu's items and the About panel's credits; `/linkproblem?text=&error=` puts a connect problem / failed-connect line on the connect card (empty clears)
- Settings: `/settings` dumps them (plus the app menu's items, the View menu's items, the shortcut sheet's rows, `devTools`/`showLog`/`recording`, and the window list); set with `accent=purple|teal|green|orange|yellow|red|blue`, `dock=0|1`, `sound=click|woodblock|tick|beep|cowbell`, `volume=`, `bpm=`/`beats=` (defaults), `connect=0|1`, `showlog=0|1`, `devtools=0|1` (shared `ui.devTools`: delete the key afterwards if it was absent), `opensin=simple|advanced`, `section=appearance|metronome|connection|device|advanced|about`, `open=1` (opens the window), `preview=1`, `forget=1` (clears the remembered pedal: shared UserDefaults, so restore `pedal.identifier` afterwards), `icon=/path.png` (writes the 1024 px recoloured icon), `sounds=1` (synth buffer stats); `/shot?target=settings&full=1&file=` screenshots the Settings window
- Live sync, monitoring, moves (`DevRemote+Live.swift`): `/live` dumps dirty, `dirtyForPrompt`, edits in flight, the unknown preset, the expression position, the reports applied; the demo pedal sends what the real one would: `knob=gain|level|bass|mid|treble|capvol|gate&raw=0..255` (26), `fx=pre1..post3&i=&raw=` (99 + its 26 companion), `bypass=<slot>&on=0|1` (31), `exp=0..255` or `sweep=0-255&steps=&ms=` (64), `state=N` (N bare 31s), `cab=1` (94), `dirty=0|1` (115), `type=&hex=` (any frame); `drag=gain|capvol|gate&v=` / `&release=1` is a knob drag in the app. `/move?from=&to=` (0-based; `choice=save|discard|cancel` answers the prompt, `async=1` returns at once, `/move?choice=` answers one that is up, `preview=from,to` shows the drag styling, `preview=0` clears it). `/mute?input=0|1&outputs=0|1` (`read=1` re-reads 66). `/fakehooks?quiet=0|1&dropstate=0|1&refuse=0|1&delay=ms&reply=ms` (demo pedal: no 115 after edits, unanswered state reads, refused 67, write delay, reply delay). `/headless?view=main|settings|captureinfo&section=device&slot=&w=&h=&file=` renders the window's content (or Settings, or the capture Info popover's content after `/captureinfo?slot=N&open=1`) offscreen: screenshots of a hidden instance
- Updates: `/updates` dumps the updater (effective feed URL, automatic checks, `canCheck`, `sessionInProgress`, last check, whether background checks are allowed, visible windows); `check=1` runs "Check for Updates…" (contacts the feed; a Sparkle error dialog is modal and pauses the dev remote until dismissed), `auto=0|1` flips the Settings switch (Sparkle stores it as shared `SUEnableAutomaticChecks`: delete the key afterwards)
Launch arguments: `-demo` connects to the fake pedal on launch, `-no-dev-remote` skips the listener (the UI tests use both).
A second instance next to Anup's (never kill his), hidden and in the background (DECISIONS #29): `open -n -g -j --env NANO_DEV_PORT=4850 "build/Build/Products/Debug/Nano Cortex Editor.app" --args -demo -connect.atLaunch NO -ApplePersistenceIgnoreState YES`, then `/demo` (it has no window, so the window's `-demo` connect doesn't run). Screenshots through `/headless`. Never activate it (no `open -a`, no AppleScript; LaunchServices would also pick the installed app, same bundle id), stop it by PID when the check is done, one instance at a time. Wait until the previous demo instance has exited before relaunching (the port stays bound otherwise), and size the window with `/resize?w=&h=` rather than `-window WxH`: with `-window` the dev remote sometimes never comes up (seen 2026-10-09).
Without `-demo`, the app connects at launch to the remembered pedal when Settings → Connection allows it (default on).
A second instance shares the owner's UserDefaults (same bundle id): put back any setting you change.
A hidden instance has no window (SwiftUI waits for activation); the dev remote starts with the app all the same.

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
