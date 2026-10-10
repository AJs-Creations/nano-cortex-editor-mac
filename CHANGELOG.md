# Changelog

All notable changes to Nano Cortex Editor for Mac. Versions follow [Semantic Versioning](https://semver.org).
The release workflow copies the section of a version into its GitHub Release notes.

## [Unreleased]

### Changed
- **Developer tools** switch in Settings → Advanced, off by default: Record, Activity (⌘L, View → Activity Log), the
  "Sent: …" status text, the Device page's hash and raw settings and a capture's hash only show with it on.
- The log file (`~/Library/Logs/Nano Cortex Editor/activity.log`) is still written for everyone, now capped: past
  about 2 MB it moves to `activity.1.log` (one old file kept).

### Added
- **Help → Show Log File** reveals the log file in Finder, for bug reports.

## [1.0.0] - 2026-10-09

First public release of the native macOS edition.

### Features
- **Bluetooth editing** of a Neural DSP Nano Cortex: connects in about two seconds, remembers the pedal and
  reconnects at launch (optional), reattaches by itself after a power cycle.
- **Preset browser**: the 64 presets with a filter, current preset highlighted, unsaved-changes prompt when you
  switch, right-click menus (load, rename, save the current sound here, assign to a footswitch, delete).
- **Save, Save as, Rename, Delete, Discard**: edits are live on the pedal; Save (⌘S) commits them. Save as writes the
  current sound into another slot; Discard reloads the preset as saved.
- **Signal chain**: gate, two pre effects, capture, cab/IR, three post effects. Bypass, change or clear any block;
  every parameter as a knob (drag, arrow keys, Shift for fine control, double-click to reset, click the value to type).
- **Captures and IRs**: the 25 capture slots and 5 cab slots of the pedal, loading from the pedal's library (factory
  and your own) with device-type and instrument icons, capture **Info…** (author, tags, hash), slot usage scan, cab
  microphone and position.
- **Footswitches**: the four 4-Preset-mode footswitch slots (IA, IB, IIA, IIB) under the preset list; click to load,
  right-click to assign.
- **Expression pedal**: per-preset sweeps (heel/toe in the parameter's units, invert) and on/off switches (heel-toe
  with delay, toggle with latch, invert), from the EXP pill in the chain.
- **Preset tempo** with − / +, a typeable field, drag and Tap; the metronome can follow it.
- **Tuner** overlay with mute.
- **Metronome**: Simple, or Advanced with time signatures, accent cells, subdivisions with swing, count-in, tempo
  trainer, gap trainer, Levels; five click sounds and any audio output.
- **Settings** (⌘,): accent colour (the Dock icon follows it), metronome defaults, connect at launch, remembered
  pedal, and a **Device** page with the pedal's name, firmware and serial, LED brightness and USB playback volume.
- **Cortex Cloud** tab: the Cortex Cloud website with its own login, and **Send to Nano Cortex** on a capture page,
  which streams the capture to the pedal's library and offers to load it into a slot.
- **Session recording** of every Bluetooth packet to JSON, and an **Activity** log (⌘L).
- **Menu bar extra**: link state, current preset with previous/next, tuner, metronome.
- **Demo mode**: a simulated pedal, to try everything without hardware.
- **Help and About**: the Help menu and Settings → About link the manual, the repository, issue reporting and the
  cross-platform edition; the connect card says why a connect isn't getting anywhere (Bluetooth off or not allowed,
  no pedal found yet) with a Troubleshooting link. A quiet **♥ Support** link sits at the right end of the status bar.

### Known limitations
- The app is **not notarised** (ad-hoc signed): the first launch needs right-click → Open, see the README.
- Footswitch assignment, expression pedal assignments, preset tempo and the Device page's LED brightness and USB
  volume were decoded from recorded traffic of the official app and verified against those recordings and demo mode;
  they are **awaiting confirmation on hardware**.
- Tested with Nano Cortex firmware 2.2.1 only.
- Presets cannot be rearranged by drag and drop yet, and Nano presets from Cortex Cloud are not supported.
- The pedal accepts one Bluetooth connection: quit the Cortex Cloud phone app first.
