# Nano Cortex Editor for macOS (native)

Native Swift/SwiftUI editor for the Neural DSP Nano Cortex, in the Cortex Control design language:
Bluetooth editing of the whole signal chain, presets, save and rename, the pedal's capture and cab library,
captures from Cortex Cloud sent straight to the pedal, tuner, metronome, menu bar controls. Unofficial.

The cross-platform Electron version lives in `nano-cortex-desktop`; both share the recorded packets that are the
protocol's ground truth.

## Install

Download the latest `nano-cortex-editor-mac-<version>-universal.zip` from the Releases page, unzip, move the app to
Applications. The build is not notarised: the first time, right-click the app → Open (or allow it in System Settings →
Privacy & Security). Requires macOS 14 or later.

Connecting: power the pedal up, hold EXIT + CAPTURE until the Gain ring lights, close the Cortex Cloud phone app
(the pedal takes one Bluetooth connection), press Connect. Edits are live on the pedal; Save (⌘S) commits them to
the preset.

## Build from source

```bash
brew install xcodegen
xcodegen generate
open NanoCortexEditor.xcodeproj      # or: xcodebuild -scheme NanoCortexEditor build
swift test --package-path NanoCore   # protocol tests, headless
swift scripts/build-icon.swift       # regenerate the app icon from App/Resources/icon.svg
```

Xcode 16+. Debug builds expose a localhost dev remote on port 4849 for hardware sessions (see `CLAUDE.md`).

## Layout

- `NanoCore/`: the protocol (framing, protobuf-style codec, messages, device state, a fake pedal for demo mode and
  tests). No UI, no CoreBluetooth.
- `App/`: the SwiftUI app (CoreBluetooth transport, store, window, Cortex Cloud tab, metronome).
- `docs/PROTOCOL-NOTES.md`: what the pedal actually does, verified on hardware.
- `PLAN.md`, `DECISIONS.md`, `VISION.md`: how the work is tracked.

Nano Cortex, Quad Cortex, Neural Capture and Cortex Cloud are trademarks of Neural DSP Technologies. This app is an
independent, unofficial tool and ships no Neural DSP artwork. IBM Plex Sans is bundled under the SIL Open Font License.
