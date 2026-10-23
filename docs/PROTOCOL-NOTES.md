# Protocol notes (copied from the Electron edition's `docs/INVESTIGATION.md` on 2026-10-08, plus later findings)

# Investigation: Cortex Control, USB, and the state of the community protocol

Done 2026-10-08 against `Cortex Control v4.1.0.pkg` (kept untracked in the repo root; `*.pkg` is ignored).
Everything below was read from the binary, Neural DSP's docs, and the public community repos. Nothing has
been verified against Anup's pedal yet.

## 1. Cortex Control 4.1.0 teardown

| Question | Finding |
|---|---|
| Tech stack | **JUCE 8, C++.** One 100 MB universal (arm64 + x86_64) binary, no `Frameworks/` folder, namespaces `neural::cortex`, `neural::mvc`, `juce::`. UI is JUCE components driven by embedded XML layouts (`presetModel.xml`, `ioSettingViewController.xml`, …). Built on Jenkins (`rol_native_cortexcontrol_develop`). |
| Linked system frameworks | IOKit, CoreMIDI, CoreAudio, AudioToolbox, WebKit, AVFoundation, Metal. **No CoreBluetooth, no IOBluetooth.** |
| Device transport | **USB HID via hidapi** (`hid_open_path`, `IOHIDDeviceSetReport`, "No HID devices with requested VID/PID found"). Hotplug scanner matches `NeuralDSP Quad Cortex`, `NeuralDSP Quad Cortex mini`, `NeuralDSP USB Audio Device`. |
| Wire format | Google protobuf, package `cortex_protobuf_v2`, descriptors embedded (`Preset.proto`, `ProductionAutomation.proto`). 72 message types (`Grid`=1 … `ModelPreset`=71), e.g. RecallPreset, Tuner, Scene, Looper, CloudProduct, LocalBackup, NeuralCapture. |
| Nano Cortex support | **None.** Zero occurrences of "nano" in 821 k strings. Manual links and copy only mention Quad Cortex and Quad Cortex mini. |
| Entitlements | audio-input, apple-events (Mail compose), unsigned-executable-memory. Not sandboxed. |

Consequences:

- The handoff's step 1 table says JUCE. JUCE has no BLE GATT client, so a JUCE port of this app would need a
  CoreBluetooth bridge in Objective-C++ on top of a C++ UI toolkit. That is the most expensive target on the list.
- Cortex Control's protocol is Quad Cortex only (HID + protobuf v2). It is **not** a route to editing the Nano
  over USB, and its message set does not match the Nano's BLE framing (see §3).
- The only thing worth borrowing from it is the information architecture, not code or protocol.

## 2. Can the Nano be controlled over USB?

Sources: Neural DSP manual ([MIDI on Nano Cortex](https://neuraldsp.com/getting-started/using-midi-on-nano-cortex), [manual](https://neuraldsp.com/manual/nano-cortex)), [rixrix/deskop-nano-cortex](https://github.com/rixrix/deskop-nano-cortex) USB probes, [Unity forum](https://unity.neuraldsp.com/t/make-the-nano-cortex-compatible-with-cortex-control/15907).

- The Nano is a class-compliant **USB audio + USB MIDI** device. No vendor control interface is documented, and
  no desktop app (official or community) edits it over USB.
- Over USB MIDI it **accepts**: Program Change 0–63 (presets), CC 34 gate bypass, CC 35 capture bypass, CC 36
  cab/IR bypass, CC 37–41 FX slots 1–5 bypass (0–63 off, 64–127 on), CC 42 tap tempo, CC 43 tuner, CC 1
  expression. MIDI channel 1–16 (set on the pedal).
- Over USB it **sends nothing back** that is useful: rixrix logged zero MIDI bytes from the pedal. No state,
  no names, no parameters.
- So USB is one-way, coarse control. Everything else (reading state, knobs, models, names, save, rename, tuner
  readout, library) is **BLE GATT only** (service A002/A003, write C304, notify C305).
- The editors do not need the Nano as an audio interface, so there is no
  reason to plug in USB except as an optional MIDI fallback. A USB cable is not needed for any feature below.

## 3. The community protocol has moved past what we vendored

| Repo | License | Last push | What it is |
|---|---|---|---|
| [choldy/nano-cortex-web-editor](https://github.com/choldy/nano-cortex-web-editor) | MIT | 2026-06-22 | Our current `editor/index.html`. Unchanged upstream since we vendored it (md5 matches). |
| [DrD85/nano-cortex-editor](https://github.com/DrD85/nano-cortex-editor) | MIT | 2026-10-08 | **A superset of choldy's**: 113 of choldy's 116 functions kept, ~130 added. Single `index.html` (285 KB script, 188 KB CSS, embedded font) plus an Electron 44 Mac shell. v1.5.2. |
| [rixrix/deskop-nano-cortex](https://github.com/rixrix/deskop-nano-cortex) | Apache-2.0 | 2026-10-05 | Rust + Tauri 2. Separate BLE encoder/decoder (`ble_encoder.rs`, `ble_schema.rs`) and USB/BLE probe binaries. Good second source for packet layouts. |

What DrD85 adds over our protocol layer (all over BLE, no MIDI):

- **Framing is now understood**: `[len = frame.length − 2] C0 [protobuf payload] [u32 LE message type]`.
  Our core treats the trailing bytes as opaque; DrD85 names them.
- **Preset switching over BLE**: `SetPresetSlotsRequest` (type 29) with `{3: context=PlayMode, 4: presetIndex,
  5–8: footswitch slots = −1, 9: currentSlot}`; device-initiated changes arrive as the same type and must be
  acked with `SetPresetSlotsResponse` (30) `{4: status=1}`. **This removes the MIDI requirement entirely.**
- **Rename** `RenamePresetRequest` (111) `{1: action=UPDATE, 3: index, 4: name}` → response 112.
- **Tuner** `TunerMode` (127) `{4: on, 5: baseFreq f32, 6: liveTuner, 7: muted}`, readings via `TunerMetering` (128).
- **Device library**: `RetrieveLibraryContent` (76/77) lists factory + Cortex Cloud captures and IRs already on
  the pedal; `SetCaptureSlotContent` (80/81) and `SetCabinetSlotContent` (78/79) load one into a slot.
- **Expression assignments** (60/61/62), **device settings** (65/66), **dirty-state notifications** (115).
- **Coalescing write queue**: one GATT write in flight, knob writes keyed per parameter so only the latest
  value is pending. This is the "responsiveness" item from the handoff, already done.
- Save-with-name frame confirmed by rixrix: `LEN C0 08 01 18 <slot> 2A <len> <name> 03 00 00 00`.
- Preset export/import as files, MIDI Learn for external controllers, MC6 Pro bank export.

Still not available anywhere: pushing a capture or IR **from Cortex Cloud** into a slot (only items already in
the pedal's library can be loaded), preset reorder/copy, and bulk backup (DrD85's per-preset export gets close).

## 4. Verified on the pedal (2026-10-08, firmware 2.2.1, factory-stock Nano)

Recording: an Electron session recording on the pedal (not published; the frames the tests assert are inlined in `RecordedFrames.swift`). Everything below was observed, not inferred.

| Action | Request | Pedal's reply | Result |
|---|---|---|---|
| Preset change | type 29 `SetPresetSlotsRequest` | `06 C0 08 01 1F…` (31), then type 30 `{4: 1}` "confirmed", then type 115 dirty=false | Works, 13/13. Pedal re-reads cleanly. |
| Amp knob / capture volume / FX param / bypass | legacy frames (types 26, 31, 99…) | type 115 `{3: 1}` (preset now dirty) | Works, audible. |
| Save | `LEN C0 08 01 18 <slot> 2A <len> <name> 03 00 00 00` | type 4 `{3: slot, 4: 1}`, then type 115 with no field 3 (clean) | Works; read-back matched every edit. |
| Rename | type 111 `{1: 1, 3: slot, 4: name}` | type 112 `{3: slot, 4: 1}` | Works. |
| Tuner | type 127 `{4: 1, 5: f32 440, 6: 1, 7: 1}` | pedal echoes type 127 with its state | Works; metering (128) only arrives while a string sounds. |
| Library capture → slot | type 80 | type 115 (dirty) then type 81 `{3: 1}` | Works. |
| Library cab → slot | type 78 | type 79 `{3: 1}` | Works. |
| Cab level | type 94 float | read-back (type 96) shows the new level | Works. |
| **Cab mic / position** | type 94 record `{1: libraryIndex, 2: cabName, 3: pos−1, 4: micName}` | read-back shows the new mic | **Upstream sends `1: 0` and the pedal ignores it.** With the cab's index in the pedal's factory IR library (field 1 of the type 96 record, e.g. 5 for "412 Brit TV GB75Hz '69") it works. Fixed in `pro/ui.js`; worth sending upstream. |
| Gate on + reduction | types 31 and 26 | state dump field 54 absent = on; **field 53 = f32 `(percent + 108) / 255`** | Works. Upstream doesn't read field 53; `pro/ui.js` does. |

Other notes:

- A preset whose cab comes from the library (not one of the 5 slots) skips the cab tone read (`Cab/IR param refresh skipped: current slot is library/unknown`). Its level/HPF/LPF knobs are stale until that is handled.
- Connect: the pedal only advertises when it is in pairing mode the first time; after that the auto-pick finds it within the 5 s scan.
- Unsaved edits are discarded by the pedal on preset change and on power-off, as in the official app.

## 5. Cortex Cloud web API (observed from the app's Cloud tab, 2026-10-08)

The website is a React app over `https://cloud-api.neuraldsp.com`. After login the token lives in the cookie
`WEB_API_ACCESS_TOKEN`, so `fetch(..., { credentials: 'include' })` from the Cloud tab is authenticated. Routes seen
in the bundle: `/login/v1/validate`, `/api/v1/user/signin|signout|profile|refresh_token`, `/homefeed/v1`,
`/search/v1/for/{preset|neuralCapture|user}?page=&query=&sort=&sortDir=&size=`, `/api/v1/products/{id}`,
`/api/v1/user/downloaded_products/{id}` (the site's "Download" button: marks the item for the user's devices),
`/api/v1/user/downloaded_products_history/…`, `/api/v1/user/products/…` (own uploads).

**The capture file itself:** `GET /api/v1/products/{id}/download` → `{ id, name, payload, payload_hash }`.
`payload` is base64 of a gzip'd **tar** containing:

- `<hash>.cns` — the Neural Capture (example: 10 350 bytes, entropy 7.98 bits/byte: encrypted or compressed), and
- `<hash>.json` — metadata: `name, authorName, authorId, cloudUUID, hash, deviceType, instrumentType, gainType,
  tags, date, description, version: "1", encryption: "Local", parametersBlockLength: "10340",
  path: "/media/p4/Captures/My Captures/<hash>.cns"`.

`hash` is the 64-hex id the pedal's own library uses (field 1 of each capture record in `RetrieveLibraryContent`),
so matching cloud items to what is already on the pedal is a string compare. `payload_hash` is just SHA-256 of the
base64 text. `compatibility` on the product record lists `quad`/`native` (and presumably `nano`).

Not yet known: how the phone app streams the tar (or its two files) into the pedal over C304. Nothing in either
community project does this. One sniffed transfer from the phone app is enough to decode it.

The downloaded bundle was used for the investigation only; no capture file is kept in the repo.

## 6. Capture transfer over Bluetooth (decoded from the phone app, 2026-10-08)

Source: a recorded phone-app session, not published: the C304/C305 packets extracted from a PacketLogger trace of the iOS Cortex Cloud app sending
two captures ("Dumbbell ODS 15", 19 811-byte `.cns`; "68 Purple Plexi Dirty", 10 350 bytes) to the Nano. GATT handles
in the trace: 0x36 = C304 (write), 0x38 = C305 (notify), MTU 517. The raw `.pklg` is not kept (it carried the phone's and
pedal's Bluetooth addresses and the pedal's serial); the extracted packets had the serial masked, and only the frames the tests need are inlined (scrubbed) in `RecordedFrames.swift`.

**Streaming.** Any message is `protobuf body + u32 LE type`. If it fits in one write it is the familiar
`[len] C0 [body] [type]`. Otherwise it is cut into 500-byte writes with a 2-byte header `[len & 0xFF, flags]`:
`flags = 0x40 first | 0x80 last | (len >> 8 & 1)`. (So `C0` = first+last, and `C1`/`81`/`41` just mean the chunk
is longer than 255 bytes.) The app pads the last write to 500 bytes. The pedal's big replies (`FE 41 …`, `FE 01 …`,
`CE 80 …`) use exactly the same scheme, which upstream calls the "FE stream".

**Upload, type 13** (phone → pedal):

```
{ 1: 6, 3: { 1: <.cns bytes>, 2: hex MD5 of the .cns bytes (32 ASCII chars) }, 4: CaptureRecord }
CaptureRecord { 1: hash, 2: name, 3: cloudUUID, 4: { 1: authorId, 2: authorName }, 5: description,
                6: deviceType ("amp_head" | "default" | …), 7: tags (repeated), 8: gainType, 10: instrumentType,
                12: version (string) }
```

All of it comes straight from the bundle's `.json` (§5). The MD5 sub-field was found while porting to Swift (byte-for-byte
golden test); the pedal accepted uploads without it, so the Electron app's omission was harmless, but the native app sends it. The pedal replies with **type 14**:
`{ 1: 6, 3: status (1 = ok), 4: { 1: userIndex, 2: name, 3: hash } }` about 0.5 s after the last write.
The app then re-reads the state (type 1 `{1: 3, 3: 1, 4: 0, 5: 1}`), re-reads the library (type 76 with only
`5: userCaptures`), and finally loads the capture into a slot with the already-known type 80
`{3: slot − 1, 5: { 1: userIndex, 2: name }}` → type 81 `{1: 6, 3: 1}`.

Also seen in the trace, not needed yet: type 46/47 (device info; firmware "2.2.1", serial), 54/55, 65/66 (settings),
91/92 (keep-alive every 20 s with firmware "2.2.1+06d34443"), and 152/153 + 164/165 (per-slot queries with a
millisecond timestamp, answered "Slot is empty").

Implementation: `pro/transfer.js` (`NanoTransfer.uploadCapture`), the "Send to Nano" button in the Cloud tab
(`src/main.js` fetches and unpacks the bundle with the Cloud session and hands it to the editor through
`src/editor-preload.js`), and `receiveCapture()` in `pro/ui.js`.

## 7. State dump details (from the Swift port, 2026-10-08)

- Reply to the metadata request (`06 C0 08 03 01 00 00 00`) is one ~10 KB streamed message that holds the **full
  current state plus** field 17 capture slots, 18 presets, 19 IR slots. The reply to the state request
  (`0C C0 08 03 18 01 20 01 28 01 01 00 00 00`) is the same layout without the lists (~380–530 B).
- Fields: 3–7 amp (gain, level, bass, mid, treble, 0–255), 9 capture bank 1–5, 11 capture position 1–5 (0 = bypass;
  absolute slot = (bank−1)·5 + position), 12 cab slot (0 = bypass), 13 preset index, 14/15/38/39 footswitch presets,
  24 firmware string, 25 device id string, 31 FX bypass bytes [pre1, pre2, post1, post2, post3] (0 = on),
  32 { 1 enabled, 2 name, 3 id } current capture, 33 { 1, 2 short name, 3 "name/mic/position" } current IR,
  34/35 capture/IR details, 41 dirty, 44 capture volume raw (−24…0 dB over 0–128, 0…+12 dB over 128–255),
  46 tuner reference (f32), **48–52 FX model ids as varints** (catalogued by their raw varint bytes in hex, e.g. 18001 =
  `D1 8C 01` = Transpose, 27 = `1B` = Green 808), 53 gate reduction f32 = (percent + 108)/255, 54 present = gate bypassed,
  56 f32 (120.0, likely tempo), 63 tuner muted.
- Preset records (field 18): 1 name ("" for empty slots), 4 author, 7 capture name, 8 capture hash prefix, 9 IR short
  name, 10 IR full name.

## 8. Captures and cabs referenced straight from the library (hardware, 2026-10-08)

A preset can reference a capture or an IR that is **not in any slot**. The state dump then reports capture
**position 6** (field 11, with the bank in field 9) or **cab slot 6** (field 12), one past the real range
(positions 1–5, cab slots 1–5). The name and hash in fields 32/33 are the library item's. Seen on a stock
pedal: preset 23 (bank 5, position 6) uses factory capture 22 "Rodent+SV 3", which no slot holds; preset 2
uses cab 6 = "110 US PRN C10R" from the library. The metadata reply still lists exactly 25 capture slots and
5 IR slots.

`StateDump.captureFromLibrary` / `cabFromLibrary` expose this; `captureSlot` is nil in that case. The usage
scan buckets such presets under slot 0. Writing a slot select (type 28) to such a preset moves it onto a slot
like any other edit. The Electron app computes slot = (bank − 1)·5 + position and shows 26 (queued there).

### Cab settings reply (type 96) and mic position, verified 2026-10-08

Record (field 5): `{1: library index, 2: short name, 3: position − 1, 4: mic, 5: short name}`; field 7 repeats
`{10: mic name}` for every mic the pedal offers for this cab; field 8 holds the level/HPF/LPF floats.
Protobuf elides defaults, so **no field 1 means index 0 and no field 3 means position 1**. The state dump's
field 33.3 `"name/mic/n"` carries the same `n = position − 1`. Writing `{1: index, 2: name, 3: pos − 1, 4: mic}`
(type 94) moved the position 3 → 4 and the mic Ribbon 160 → Dynamic 57 on "110 US PRN C10R" (index 0), and both
read-backs agreed. Re-selecting the cab slot reloads the slot's stored mic, so read back with a type-95 refresh.

## 9. Deleting a preset (decoded from the phone app, 2026-10-08)

Source: a recorded phone-app session, not published, the iOS Cortex Cloud app deleting presets
63 and 64. One write per preset:

```
type 50  { 1: 2, 3: index }              08 02 18 3E  → preset 63 (0-based 62)
type 31  { 1: 1 }                        unsolicited notice on C305, ~110 ms later
type 51  { 1: 6, 3: index, 4: 1 }        ack, 4 = status (1 = ok)
```

After the ack the app re-reads the lists with type 1 `{1: 3, 3: 0, 4: 1, 5: 1}` (type-2 reply, ~6 KB, presets
only); the slot then comes back with an empty name. Field 1 = 2 is presumably the item kind (preset); captures
and IRs in the library are likely the same message with another kind — untested. Also in this trace, not needed
yet: type 152/153 and 164/165 `{1: 3, 2: <id varint>, 3: n}` for n = 0…4 answered with `"Slot is empty"`, type
46/47 device info, 54/55, 65/66 settings, 91/92 keepalive (the app sends it every ~55 s).

The 2026-10-09 phone-app session (footswitch assignment, tempo, expression, global settings, capture mode) is decoded in `docs/TRACE-2026-10-09.md`.

## 10. Footswitch assignment (decoded from the phone app, 2026-10-09)

Source: the 2026-10-09 recorded phone-app session, not published. In 4-Preset mode the pedal has four
footswitch preset slots, footswitch I / II × bank A / B. They live in the state dump and in type 29:

| Slot | State dump (type 2) field | Type 29 field |
|------|---------------------------|---------------|
| IA   | 14                        | 5             |
| IB   | 15                        | 6             |
| IIA  | 38                        | 7             |
| IIB  | 39                        | 8             |

Values are 0-based preset indexes; a missing state field is 0 (protobuf default), so "preset 1" is an absent field.

- **Preset change** (ours): type 29 `{3: 0, 4: index, 5..8: −1, 9: slot}`; field 9 is the slot 0–3 (IA…IIB) that
  holds the preset, 4 when it is on none. The trace: preset 8 on IIA sent `9: 2`, preset 16 on IIB `9: 3`.
  −1 is the 10-byte varint `FF FF FF FF FF FF FF FF FF 01`.
- **Assign**: the same message with field 4 = −1, the target slot's field = the preset, the other three −1, field 9 = 0.
  The pedal answers 115 `{1: 1}`, 31 `{1: 1}`, 30 `{1: 1, 4: 1}`; the app then re-reads the state (type 1).
  Preset 15 (index 14) → IA:
  ```
  36 C0  18 00  20 FF FF FF FF FF FF FF FF FF 01  28 0E  30 FF…FF 01  38 FF…FF 01  40 FF…FF 01  48 00  1D 00 00 00
  ```
- **Footswitch press on the pedal**: type 29 `{1: 1, 4: index, 5..8: the four slots}`; the app acks with type 30
  `{4: 1}` and re-reads the state.
- Open: one change in the trace (to preset 14, held by IA) carried `10: 0` instead of field 9; unexplained, not used.
- **An assignment drops unsaved edits** (seen once, trace at ~649 s): the preset was dirty, the pedal answered with
  115 `{1: 1}` (clean) and the next state was the stored preset. Both editors ask "Save changes to X?" first
  (Cancel / Don't save / Save and assign), like a preset switch.

## 11. Tempo (decoded from the phone app, 2026-10-09)

Source: the 2026-10-09 recorded phone-app session, not published (203–279 s), the iOS Cortex Cloud app changing a preset's tempo
and saving it four times. Golden tests: `NanoCore/Tests/NanoCoreTests/TempoTests.swift`.

| Type | Dir | Fields | Meaning | Confidence |
|---|---|---|---|---|
| 145 | tx | `{3: 1, 4: 0, 5: bpm f32, 6: 0}` | Live tempo: the pedal plays it; the preset stays clean (no 115) | confirmed |
| 145 | tx | `{3: 0, 4: 0, 5: bpm f32, 6: 0}` | Write the tempo into the preset: 115 `{3: 1}` (dirty) follows, no echo; a type-3 save commits it | confirmed |
| 145 | tx | `{3: 1, 4: 0, 6: 0}` (no 5) | Query: answered by the echo with the current tempo | confirmed |
| 145 | rx | `{1: 1, 3: 1, [4: 1,] 5: bpm f32}` | Echo: after the first live write of a drag, after a query, and unsolicited when the tempo changes on the pedal (hold footswitch I, tap) | confirmed (pedal-side tap: per the trace write-up) |
| 2 | rx | state field 56 (f32) | The preset's stored tempo in BPM (93 → 114 → 222 → 106 after the four saves) | confirmed |

```
live 120     0F C0 18 01 20 00 2D 00 00 F0 42 30 00 91 00 00 00
preset 93    0F C0 18 00 20 00 2D 00 00 BA 42 30 00 91 00 00 00
echo 120     0D C0 08 01 18 01 2D 00 00 F0 42 91 00 00 00
```

The official app sends scope 1 while its knob moves and one scope-0 write with the final value right before Save.
Both editors do the same: live writes while stepping/dragging/tapping, then (on release, Enter, or when steps and
taps settle) a live write and a scope-0 write with the final value, which marks the preset edited; Save commits it.
Range 30–300 BPM (clamped by our writers). **Field 4 (unverified):** the app's other control sent `4: 1` and the
pedal kept a separate value for it (possibly Tempo Mode global vs preset); we always send `4: 0` and read an echo
with `4: 1` the same way. Whether a scope-0 write alone also changes what you hear is not visible in the trace.

## 12. Expression assignments (types 60–64; phone-app trace 2026-10-09 + upstream)

Sources: the 2026-10-09 recorded phone-app session, not published (321.6–382.4 s, preset index 61) and the upstream editor's
`EXP_RANGES` / `EXP_BYPASS` / `expSaveFrame`. Where both cover a field they agree byte for byte; the trace wins elsewhere.
Implementation: `NanoCore/Sources/NanoCore/Expression.swift`, golden tests in `ExpressionTests`.

| Type | Dir | Body | Meaning |
|---|---|---|---|
| 60 | tx | `{1: 3, 3: presetIndex}` | Read the preset's set. `08 03 18 3D` = index 61 |
| 64 | rx | `{1: 1, 3: 2}` | Between 60 and 61 (ignored while a 60 is outstanding); otherwise `{1:1 3:2 4:position}` is the expression pedal's position (§14). `{1:1 5:1}` / `{1:1 3:1 5:1}` stream in capture mode, ignored |
| 61 | rx | `{1: 1, <records at save field − 1>}` | The set; `{1: 1}` alone = none (trace). The −1 shift is upstream's only |
| 62 | tx | `{3: presetIndex, <records>}` | Replaces the **whole** set; `{3: presetIndex}` alone clears it |
| 63 | rx | `{1: 1, 3: 1}` | Ack, 3 = ok (one per 62) |
| 115 | rx | `{1:1 3:1}` / `{1:1}` | Dirty after a change; clean again when the set matches the saved one (cleared back to empty) |

Record fields in a 62 (reply 61: field − 1). **T** = in the trace, **U** = upstream only.

| Field | Target | Record | Source |
|---|---|---|---|
| 4 / 5 / 6 / 7 | Gain / Bass / Mid / Treble | range | 4, 5 T; 6, 7 U |
| 8 / 9 | Pre FX 1 / Pre FX 2 amount | range | U |
| 10 / 11 / 12 | Post FX 1 / 2 / 3 amount | range | U |
| 13 | Level (capture volume) | range | U |
| 14 | Capture bypass | bypass | T (heel-toe) |
| 15 | Cab / IR bypass | bypass | U |
| 16 / 17 | Pre FX 1 / Pre FX 2 bypass | bypass | 17 T (switch); 16 U |
| 18 / 19 / 20 | Post FX 1 / 2 / 3 bypass | bypass | U |
| 21 | Input gate amount | range | U |
| 22 | Input gate bypass | bypass | U |

- **Range** `{1: inverted, 2: min (heel), 3: max (toe)}`, raw 0–255, all three written even when zero (`08 00 10 00 18 FF 01`).
- **Bypass** is a oneof: `1` heel-toe `{1: inverted, 2: switchDelay ms}` (T: 600, 693), `2` switch `{1: inverted, 2: latchEmulation}`
  (T: 0, 1), `3` stop `{1: switchDelay ms}` (U). Upstream clamps the delay to 0–2000 ms.

Exact bodies (trace, index 61): gain 0–255 `18 3D 22 07 08 00 10 00 18 FF 01`; gain + bass
`18 3D 22 07 08 00 10 00 18 FF 01 2A 07 08 00 10 00 18 FF 01`; capture heel-toe 600 ms `18 3D 72 07 0A 05 08 00 10 D8 04`
(693 ms: `… 10 B5 05`); Pre FX 2 switch, latch on `18 3D 8A 01 06 12 04 08 00 10 01` (off: `… 10 00`); clear `18 3D`.

Unverified: whether a set survives a preset change or power cycle without a type-3 save (the 115 says it sits in the
edit buffer; the editors mark the preset edited and let Save commit); the units of the non-amp ranges (the native
panel shows capture volume on the capture-volume dB curve and everything else as % of 0–255); what the FX "amount"
ranges drive (the block's main parameter, presumably); the order of records the official app uses beyond 4, 5 (we write
ascending field numbers); the inverted flag = 1 and the stop mode on the pedal; calibration (not in the trace).

## 13. Device settings and capture details (decoded from the phone app, 2026-10-09)

Source: the 2026-10-09 recorded phone-app session, not published (serial masked); full write-up of that trace in
`docs/TRACE-2026-10-09.md` (§2.7, §2.9, §2.13). Golden tests: `DeviceTests`.

### Device info: 46 → 47, keep-alive 91 → 92

```
tx 46  { 1: 3, 3: Unix time (s) }                     08 03 18 C4 82 A5 D6 06   (1791574340)
rx 47  { 1: 1, 3: 1, 4: "", 5: firmware, 6: serial, 7: 64 hex }
tx 91  { 1: 3 }                                        06 C0 08 03 5B 00 00 00
rx 92  { 1: 3, 3: 1, 5: firmware build, 6: serial, 7: device name }
```

| Field | Meaning | Confidence |
|---|---|---|
| 47.5 | Firmware, `"2.2.1"` | confirmed (matches state field 24) |
| 47.6 / 92.6 | Serial (masked `XXXXXXXXX` in the trace) | confirmed |
| 47.7 | 64 hex characters, **different on every request** (2.85 s vs 5.64 s) | unknown (a reply to the clock in 46.3?) |
| 47.4 | Always `""` | unknown |
| 92.5 | Firmware build, `"2.2.1+06d34443"` | confirmed |
| 92.7 | Device name, `"Neural DSP Nano Cortex"` | confirmed (same as 66.5) |

### Global settings: 65 → 66, write 67 → 68

```
tx 65  { 1: 3 }
rx 66  { 1: 1, 3: 1, 5: name, 6: 153, 7: 1, 8: 1, 11: 0, 12: 1, 13: 129, 14: 1, 17: -6.0 }   (session start)
tx 67  { 1: 1, 4: brightness, 14: USB dB (f32) }       08 01 20 99 01 75 00 00 C0 C0   (153, −6.0)
rx 68  { 1: 1, 3: 1 }                                  3 = ok, one per 67
```

| 67 field | 66 field | Meaning | Confidence |
|---|---|---|---|
| 4 (varint 0–255) | 6 | **LED brightness**; the app's slider ended on 153 = 60 %, the manual's default | confirmed shape, meaning by value/default (exposed) |
| 14 (f32 dB) | 17 | **USB playback volume**; swept −13.9…−5.5, ended −6.0, the manual's default | confirmed shape, meaning by value/default (exposed) |
| — | 5 | Device name | confirmed (read-only here) |
| 9 | 12 | Toggle; 9:0 made the pedal re-send its preset (rx 29); state field 37 present ↔ 1. Candidate: 4-/2-preset mode | **unverified** |
| 12 (varint, explicit 0/1) | 15 | **Mute Input** (the Guitar Input; USB input still plays) | confirmed (Electron #14; exposed) |
| 13 (varint, explicit 0/1) | 16 | **Mute Outputs 1L/2R** (the processed sound; USB playback still plays) | confirmed (Electron #14; exposed) |
| 7, 8, 18 | ? | Booleans | **unverified** |
| 15 | ? | 3-way choice (MIDI clock source?) | **unverified** |
| 16 | ? | 4-way choice | **unverified** |
| — | 7, 8, 11, 13, 14 | 13 read 129, and 172 during capture mode | **unverified** |

The phone app sends 4 and 14 together in every write while either slider moves (≈85 ms apart), and nothing dirties
the preset (no 115). Both editors do the same: only after a successful 65 read (so the other value is the pedal's
own), one write in flight, newer values replace the queued one. 66 = 67 + 3 fits 9↔12 and 14↔17 but not 4↔6, so
66 probably has an extra field between 6 and 12. Exposed: 4 and 14, and the two mutes; the rest is a read-only "Raw
settings" line.

Monitoring writes carry one field each, always with an explicit 0 or 1: Mute Input on/off
`08 C0 08 01 60 01 43 00 00 00` / `08 C0 08 01 60 00 43 00 00 00`, Mute Outputs 1L/2R on/off `… 68 01 …` / `… 68 00 …`;
the ack is `08 C0 08 01 18 01 44 00 00 00`. 66 reads them back with tags `78` (15) and `80 01` (16); left out = off.
The 68 doesn't say which write it answers, so the editor sends one 67 at a time (brightness/USB writes included) and
reads 66 back after each accepted mute. The tuner and Mute Input: the pedal still reports the input muted after the
tuner closes, but its audio path needs a fresh off → on to mute again (seen on a pedal, Electron #14). Both editors note
the mute when the tuner opens and, when it closes with the input muted, wait for the tuner-off write, 200 ms, send off
and, 100 ms after that write, on again, unless the mute was changed meanwhile.

### Capture details: 17 → 18

```
tx 17  { 3: slot − 1, 5: 1 }                           08 C0 18 00 28 01 11 00 00 00   (slot 1; the 0 is explicit)
rx 18  { 1: 6, 3: status, 7: { 1: author id, 2: author name }, 8: "", 9: hash, 10: name, 11: CaptureRecord }
```

Field 11 is byte-identical to state field 34 for the active capture and parses with `CaptureRecord.decode`
(1 hash, 2 name, 4 author, 6 device type `amp_head`, 7 tags, 8 small int (gain type?), 10 instrument `guitar`,
12 version `"1"`). 18.8 may be the description (empty on both captures seen; **unverified**); 17.5 = 1 is unknown.
Seen: slot 1 "CA John's Ch1 1" (tags Mesaboogie, JP2C, Mesa, Boogie, John, Petrucci), slot 12 "Brit 2555 Rhy 12".

## 14. Live reports and preset moves (contributed in the Electron edition's #14, firmware 2.2.1)

Sources: a contributor's phone-app BLE captures (2026-10-14/15; not published) and their hardware tests, as written up in
the Electron edition's `docs/INVESTIGATION.md` §12. Implementation: `NanoCore/Sources/NanoCore/LiveReports.swift`
(parsing, the 143 frame, the 67 mute writes; `LiveReportsTests`), `App/Sources/PedalStore+Live.swift` (applying them),
`App/Sources/PresetReorder.swift` (moves). Protobuf leaves zero values out, so a missing field means 0.

**Live reports (pedal → app, unsolicited).**

| Type | Body | Meaning | Editor |
|---|---|---|---|
| 26 | `{1:1 3:control 4:raw 6:1}` | A knob moved: control 0 gain, 1 level, 2 bass, 3 mid, 4 treble, 10 capture volume, 11 gate (raw − 108 = reduction %) | applied; other controls → one state read |
| 99 | `{1:1 3:FX slot 0–4 4:param index 5:raw 0–255 (f32)}` | An FX parameter moved; comes with a type-26 control 6 carrying the same raw value | applied by slot and index (raw / 255 → the parameter's range, on its step); the companion is dropped |
| 31 | `{1:1 3:enable slot 4:0 on / 1 off}` | An FX block switched (enable slots 4–8 = Pre FX 1 … Post FX 3): footswitch, the expression pedal's switch, USB MIDI CC | applied, unless the user's own click is still unconfirmed |
| 31 | `{1:1}` | Something changed | one coalesced state read (FX models kept) |
| 64 | `{1:1 3:2 4:position 0–255}` | Expression pedal position (heel: field 4 left out) | amp knobs, capture volume and gate follow the assigned ranges (heel/toe raw 0–255, inverted swaps them); an FX Amount only where the parameter is known (Mix / Amount, Transpose → Semitones); heel-toe switches flip only at the ends (≤ 2, ≥ 253); a throttled (250 ms) read-back (137) of the assigned FX blocks that are on shows the rest |
| 94 | — | A cab parameter changed | one state read |
| 115 | `{1:1 3:dirty}` | Preset dirty state | the only source of the unsaved-changes mark (plus an in-flight guard for the prompts) |

Reports for a control the user is dragging wait: the user's value is written at the end of the gesture and wins (and a
report up to 250 ms after it is dropped as an older value). Several reports without context make one state read, after
the reads and writes in flight; a preset load drops it. A 66 the pedal sends unasked updates the mutes.

**Preset move.** One message moves a preset by insertion (the presets in between shift by one); indices are 0-based and
absolute (a filtered list changes nothing):

```
143 { 1: 4, 3: <from>, 4: <to> }          e.g. 5 → 3: 0A C0 08 04 18 04 20 02 8F 00 00 00
144 { 1: 6, 3: <from>, 4: <to>, 5: 1 }    5 = 1: moved
```

Then the editors read the preset list (the metadata read) and the state again. The pedal sent 115 dirty then clean around
one move; the editors ignore 115 while a move is outstanding and take the dirty state from the state read after it.
Observed moves: 5 → 3 and 36 → 6. How footswitch assignments and the current preset follow a move is read from the pedal
afterwards, not assumed (the demo pedal moves both with their presets). A failed or unconfirmed move ends with the order
read from the pedal; if the state read fails, the current preset is unknown and Save, Save as, Discard and Rename stay off
until a read succeeds. A left-out 144 field reads 0 in both editors.

## 15. Cloud IRs, auditions and deleting an IR (the Electron edition's INVESTIGATION §6a and §12, from its PR #14)

Sources: a contributor's iOS Bluetooth captures (2026-10-14/15, firmware 2.2.1; not published) and their hardware
tests, ported into the Electron edition in its PR #14; a local BLE capture of the phone app deleting one user IR.
**None of this is verified on Anup's pedal yet** (the PR's checklist). Code: `NanoCore/Audition.swift`,
`IRTransfer.swift`, `DemoTransfers.swift`; the app's `PedalStore+Audition.swift`, `CloudIR.swift`,
`IRLibraryView.swift`. Golden tests: `AuditionTests`, `IRTransferTests`.

### Cloud IR into the pedal's library: 15 → 16 (streamed like 13)

```
15  { 1: 6, 3: { 1: <WAV bytes>, 2: <32-char lowercase MD5 hex of the WAV> }, 4: <product UUID>, 5: <file name ending .wav> }
16  { 1: 6, 3: 1, 4: { 1: <user IR index>, 2: <name> } }          3 = 1: accepted
```

The traced WAV was 4,154 bytes: mono, 48 kHz, IEEE float32, 1,024 samples. The phone then reads the state (1) and
the library (76 → 77); the new IR sits at the index 16 gave. No 13 and no slot load (78): putting it in a slot is a
separate step. Cortex Cloud's `GET /api/v1/products/{id}/download` returns `{ id, name, payload, payload_hash }`; for
an IR, `payload` is base64 of the raw RIFF/WAVE file (not a tar). The account's list (`/cloud/profile/impulses`, API
`/search/v1/for/impulseResponse?…&ownedByMe=true`) carries each IR's `productId` and `name`. The MD5 is computed from
the decoded WAV, not taken from `payload_hash`. Before sending, both editors refuse a payload over 1 MB decoded
(checked on the base64 length first), and a WAV without a `fmt ` chunk of PCM 16/24/32-bit or float 32/64-bit, 1–2
channels and 8–192 kHz (WAVE_FORMAT_EXTENSIBLE resolved to its sub-format), or without a non-empty `data` chunk.

### Deleting a user IR: 82 → 83

```
82  { 1: 2, 4: { 1: <library index>, 2: <name> } }    e.g. { 1: 2, 4: { 1: 0, 2: "My IR" } }   11 C0 08 02 22 09 08 00 12 05 4D 79 20 49 52 52 00 00 00
83  { 1: 6, 3: 1 }
```

Index and name exactly as 77 lists them; the phone then re-reads the library. Indices shift when an IR is added or
removed, so the editors read the library again right before the 82 and send it only if that index still holds that
name. User IRs only; factory cabs are not deletable.

### Capture preview (Cortex Cloud "Play"): 150 → 151, stop 148 → 149

```
150 (streamed) { 5: { 1: { 1: <.cns bytes>, 2: <hex MD5 of the .cns> }, 2: <CaptureRecord as in 13> }, 7: 2, 8: 1 }
151            { 1: 6, 3: 1, 4: { 1: 2, 2: <name>, 3: <hash> } }          3 = 1: playing
148            { 2: <transaction>, 3: 0 }                                   stop (capture)
149            { 1: 1, 2: <same transaction>, 3: 1 }                        stopped
```

Nothing is written to a slot or the library.

### Library IR audition: 158 → 159, stop 148 → 149

```
158 { 3: { 1: <factory index>, 2: <name> }, 8: 1 }   or   { 4: { 1: <user index>, 2: <name> }, 8: 1 }
159 { 1: 6, 3: 1, 4: { 2: <name> } }                  3 = 1: playing; a new 158 replaces the IR playing
148 { 2: <transaction>, 4: 0 }                         stop (IR)
149 { 1: 1, 2: <same transaction>, 3: 1 }
```

Factory cab 0 "412 V30": `13 C0 1A 0B 08 00 12 07 34 31 32 20 56 33 30 40 01 9E 00 00 00`. The trace shows field 3
for a factory cab; field 4 for a user IR is the matching guess (**unverified**).

The transaction is the app's millisecond clock (a varint past 2³²); the pedal echoed it in both 149s seen, and the
editors take a stop as confirmed only with that echo and status 1 (otherwise the audition may still be playing: it
stays marked active and nothing that depends on the stop happens). While anything is auditioned, the app sends the
keep-alive **91** `{1: 3}` about every 20 s and the pedal answers **92** `{1: 3, 3: 1, …}` (§13); without it the pedal
ends the audition after about a minute. After an IR stop the app reads the current state; the pedal may then report
the preset dirty (115) although nothing was edited. What happens to an audition when the preset changes on the pedal
(footswitch) is not known: the editors send the stop anyway and forget it.

Streamed messages (13, 15, 150) go out one at a time in both editors: their parts only make sense together and each
waits for its own reply.
