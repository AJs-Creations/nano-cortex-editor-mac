# Vision

A native macOS editor for the Neural DSP Nano Cortex that feels like a system app: it remembers the pedal and
reconnects by itself, lives in the menu bar, launches instantly, and does everything the Electron editor does
(`../nano-cortex-desktop`, the reference implementation and the shareable cross-platform version).

**What it must do (parity with the Electron app, in this order):** connect and sync; edit amp, effects, gate, cab live;
switch, save and rename presets over Bluetooth; tuner; load captures and cabs from the pedal's library into slots;
browse Cortex Cloud and send captures to the pedal; metronome.

**What it adds:** auto-reconnect through CoreBluetooth, menu bar controls (preset up/down, tuner, metronome),
Passwords autofill in the Cloud web view, a small, fast app.

**What it is not:** official. No Neural DSP logos; the trademark note stays in the README.

**Users:** Anup first; sharing is possible later (notarisation needs the paid Apple Developer account).
