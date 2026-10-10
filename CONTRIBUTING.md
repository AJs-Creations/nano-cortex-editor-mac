# Contributing

Thanks for helping. This is a small, unofficial project; issues and pull requests are welcome.

## Branches and pull requests
- Work on a `feature/*` (or `fix/*`) branch from `staging`.
- Open a pull request into **`staging`**. CI must be green.
- `staging` → `main` by pull request when a set of changes is ready to release. Nobody pushes to `main` or `staging`
  directly.
- Releases: a `v*` tag on `main` (e.g. `v1.0.1`) runs `.github/workflows/release.yml`, which builds the universal app,
  ad-hoc signs it, zips it and creates the GitHub Release with the notes from `CHANGELOG.md`. Add a section for the
  version to `CHANGELOG.md` before tagging, and bump `MARKETING_VERSION` in `project.yml`.

## Building and testing
```bash
brew install xcodegen
xcodegen generate                    # the .xcodeproj is generated from project.yml and not committed
swift test --package-path NanoCore   # protocol core (headless, fast)
xcodebuild -project NanoCortexEditor.xcodeproj -scheme NanoCortexEditor -destination 'platform=macOS' -only-testing:NanoCortexEditorTests test
xcodebuild -project NanoCortexEditor.xcodeproj -scheme NanoCortexEditor -destination 'platform=macOS' -only-testing:NanoCortexEditorUITests test   # takes over the pointer
```
CI (`.github/workflows/ci.yml`) runs the core tests, the app build, the app unit tests and the demo-mode UI smoke
test on every pull request and on pushes to `main` and `staging`.

- `NanoCore` stays headless: no UI, no CoreBluetooth. New protocol behaviour gets a test there.
- Edit `project.yml`, not the Xcode project.
- Keep demo mode working: it is what the UI test, the screenshots and new contributors run on.
- Protocol-level UI (Record, Activity, ⌘L, hashes, raw fields, "Sent: …") sits behind **Settings → Advanced →
  Developer tools** (`AppSettings.devTools`, UserDefaults `ui.devTools`, off by default). Turn it on to work on the
  protocol; launch with `-ui.devTools YES` to enable it for one run without changing your setting. Docs screenshots
  are taken with it off unless they show a developer feature.

## The dev remote
Debug builds start a localhost-only HTTP server (default port 4849, `NANO_DEV_PORT` to change it) that can drive and
inspect the app: `/state`, `/ui`, `/log`, `/shot?file=…`, one endpoint per action. The full list is in `CLAUDE.md`.
Release builds don't include it. A second instance for testing:
```bash
open -n --env NANO_DEV_PORT=4861 "build/Build/Products/Debug/Nano Cortex Editor.app" --args -demo -connect.atLaunch NO
curl 'http://127.0.0.1:4861/shot?file=/tmp/shot.png'
```

## Hardware and the protocol
- Edits are live on the pedal; only an explicit user action saves, renames, deletes or loads into a slot. Never add
  code that writes to the pedal on its own.
- Before sending a new kind of message to a real pedal, find the same bytes in a recording of the official app. If
  there is none, record first. Document findings in `docs/PROTOCOL-NOTES.md`.
- Back up your presets in the official app before testing writes.

## Recordings are never committed
Session recordings (the **Record** button), phone-app traces, PacketLogger/HCI captures (`.pklg`) and capture files
contain a pedal's serial, device ids, users' preset and capture names and third-party content. **They are never
committed**, not even scrubbed. `.gitignore` excludes them (debug builds save recordings into the ignored
`recordings/` folder). When a test needs recorded traffic, inline only the frames it asserts, with identifying strings
replaced at the same length, as in `NanoCore/Tests/NanoCoreTests/RecordedFrames.swift`, or generate the data with
`FakePedal`/`StateEncoder`.

## Style
- Swift 6 with strict concurrency; small focused types; explicit errors.
- Commit messages: imperative summary line, a body explaining why.
- No Neural DSP logos or artwork; keep the trademark note in the README and the manual.

## License
By contributing you agree that your contributions are licensed under the MIT License (see `LICENSE`).
