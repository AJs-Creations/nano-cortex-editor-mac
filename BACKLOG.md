# Backlog — Nano Cortex editors

Soft list of ideas Anup may come back to. Not a plan: `PLAN.md` holds committed work. Items here are a preview of
what's on his mind; Claude may add suggestions (marked). Picked items become PLAN rows.

## Native-only advantages (2026-10-09, from the "what does native give us" discussion)
- App Intents: Shortcuts, Siri and Stream Deck actions ("Switch to preset Lead", "Next preset", "Toggle tuner", "Start metronome at 120"). Biggest native-only win for a musician.
- Always-on helper: keep the Bluetooth link with the window closed, reconnect in the background, preset in the menu bar, a small always-on-top performance panel; ~30 MB resident, fine at login.
- Global hotkeys: change presets or open the tuner from inside Logic or a browser.
- Remembered peripheral: native reconnects without a device picker (already true; keep it that way).
- CoreMIDI: program changes over USB as a Bluetooth fallback; the app as a MIDI destination for a DAW or foot controller.
- System integration: Spotlight indexing of presets/captures, a desktop widget with the current preset, link-drop notifications, a document type for preset backups with Quick Look, window restoration.
- Lower-latency audio: a Mac-side tuner from the audio input; the metronome click on a specific interface.

## Both editors
- Rearrange presets by drag and drop, as in the official app (needs one phone-app trace of a single drag; PLAN row 22).
- (Claude) Library management: delete captures/IRs from the library — probably type 50 with another kind; needs a trace.
- (Claude) Nano presets and custom IRs from Cortex Cloud (one trace each).
- (Claude) Strobe tuner from the pedal's USB audio (or any interface input): pitch analysis in the app; the pedal only streams note + cents
- 2026-10-09 — Metronome, planned next (Anup): polyrhythms (two patterns against each other) and custom click samples (user-provided audio files for accent / main / sub)
- (Claude) Metronome extras: MIDI clock out, syncing the pedal's delay tempo

## Electron
- Windows build is untested on real hardware.

## Native
- Dock icon after quit shows the bundle's blue icon, not the chosen accent. Tried on 2026-10-09: writing a Finder custom icon into the .app (NSWorkspace.setIcon) breaks the code signature and the next launch fails ("Launchd job spawn failed"), so it was reverted. Only fix left: bake the accent in at build time, or ship one bundle per accent. Live Dock icon follows the accent while running.
