# Changelog

All notable changes to Nano Cortex Editor for Mac. Versions follow [Semantic Versioning](https://semver.org).
The release workflow copies the section of a version into its GitHub Release notes and into the update alert.

## [Unreleased]

### Added
- **Live sync with the pedal**: knobs, effect parameters, footswitch bypasses (and bypasses from the expression pedal's switch or a USB MIDI CC) and the expression pedal update the editor as they change on the pedal; the unsaved-changes mark follows the pedal's own report.
- **Reorder presets** by dragging a row onto another (works with the filter on); the order is read back from the pedal.
- **Monitoring** in Settings → Device: Mute Input and Mute Outputs 1L/2R; a header **Mute** button for the input, read from the pedal at connect.
- **Cortex Cloud IRs to the pedal**: **Send to Nano** on each IR in your Cloud profile's Impulse Responses list (and
  **IRs** in the toolbar). WAV files up to 1 MB, PCM or float, mono or stereo.
- **Auditions**: **Live Preview** plays a Cloud capture on the pedal without storing it (with **IR: On / Off**), and
  ▶ on a library IR in the Cab / IR inspector plays it without loading it into a slot. Saving or changing the preset
  stops an audition first; if the pedal doesn't confirm the stop, the action doesn't happen.
- **From the library** in the Cab / IR inspector: factory cabs and your IRs with search, audition and **Delete…** for
  your own IRs.
- One transfer to the pedal at a time: a capture, an IR or a preview; another one is refused with a message until the
  first has finished.

### Fixed
- "Unsaved changes" stayed after you put your edits back the way they were saved: the mark, Save and Discard now follow the pedal's report.
- Closing the tuner keeps the guitar input muted if it was (the pedal needs the mute re-applied).

The Cloud IR, audition and IR delete entries port the Electron edition's, contributed there by @itsbreaded (its #14);
they are not yet verified on a pedal.

## [1.1.0] - 2026-10-20

### Added
- **Updates**: the app tells you when a new version is out and installs it for you.
- **Metronome sounds from your own samples**: Settings → Metronome → Sounds sets the accent, main beat and subdivision to a built-in sound or a custom sample (WAV, AIFF, CAF, MP3, M4A or FLAC).

### Fixed
- Connecting: the app remembers a pedal only once its editor service is ready, forgets a remembered device that turns out not to be a Nano Cortex, and stops with a clear message instead of waiting forever when the setup fails, times out (10 s) or connecting keeps failing.

## [1.0.0] - 2026-10-10

First public release of the native macOS edition.

### Added after release (same version)
- Signed with a Developer ID and notarised by Apple, so the download opens without security workarounds.

### Developer tools
- **Developer tools** switch in Settings → Advanced, off by default: Record, Activity (⌘L, View → Activity Log), the
  "Sent: …" status text, the Device page's hash and raw settings and a capture's hash only show with it on.
- The log file (`~/Library/Logs/Nano Cortex Editor/activity.log`) is still written for everyone, now capped: past
  about 2 MB it moves to `activity.1.log` (one old file kept).

### Help
- **Help → Show Log File** reveals the log file in Finder, for bug reports.

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
- Footswitch assignment, expression pedal assignments, preset tempo and the Device page's LED brightness and USB
  volume were decoded from recorded traffic of the official app and verified against those recordings and demo mode;
  they are **awaiting confirmation on hardware**.
- Tested with Nano Cortex firmware 2.2.1 only.
- Presets cannot be rearranged by drag and drop yet, and Nano presets from Cortex Cloud are not supported.
- The pedal accepts one Bluetooth connection: quit the Cortex Cloud phone app first.
