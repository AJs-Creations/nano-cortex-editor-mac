# Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Separate repo from the Electron app; that app stays the reference and the shareable build | Fallback and Windows coverage stay intact; the native app can diverge in UI without breaking the reference |
| 2 | Swift 6, SwiftUI, minimum macOS 14 | Modern SwiftUI (Observation, MenuBarExtra); owner runs macOS 27 |
| 3 | Hand-written protobuf codec, no SwiftProtobuf | The pedal's messages are small and partly undocumented; the JS implementation is the verified reference and ports one to one; golden tests against recordings replace a schema |
| 4 | `NanoCore` is a Swift package with no CoreBluetooth or UI dependency | Headless tests against recorded packets; transport is a protocol with a `FakePedal` implementation |
| 5 | XcodeGen generates the project from `project.yml`; the `.xcodeproj` is git-ignored | Agent edits and diffs on YAML/Swift instead of `pbxproj` |
| 6 | Bundle id `com.community.nanocortex`, product name "Nano Cortex Editor" | Owner's choice |
| 7 | Not sandboxed, hardened runtime on, unsigned builds | CoreBluetooth and the Cloud web view work without entitlement work; signing/notarisation only if sharing happens |
| 8 | Upload writes are 500 bytes with the last one padded, exactly like the official app | Proven on the pedal; byte-for-byte golden test in `CaptureUploadTests` |
| 9 | Fixtures are copied from the Electron repo, never raw HCI traces | The raw trace carried device addresses and the pedal serial (see that repo's history purge) |
| 10 | `Session.events` carries only unsolicited traffic; a request's reply goes to its caller alone | Otherwise every reply was applied twice (caller + event) and the sync refreshed each block three times. The store applies what it asked for and listens for what the pedal volunteers (footswitch preset changes, dirty flag, tuner, library). |
| 11 | The cab mic/position controls say, in the inspector, that they change the cab slot for every preset | Verified on the pedal 2026-10-08: a type-94 mic/position write lands in the cab slot, survives a preset switch without a save, and every preset using the slot hears it. The preset's own edits (slot choice, level, filters) still need Save. |
| 12 | Accent colours are computed from `AppSettings` (UserDefaults); purple keeps its exact original constants, other accents derive highlight/row/focus by mixing; the Dock icon and header mark recolour `icon.svg`'s LED gradient at runtime, the asset-catalog icon stays teal | A fresh install looks exactly as before; one observable source re-renders every view; no extra icon assets |
| 13 | The metronome starts at Settings' default tempo each launch; overlay tempo changes are session-only; volume, output and sound are shared with Settings | Owner's spec (settings are the defaults); the old last-used `metro.bpm` seeds the default once |
| 14 | The native app's default accent (and Dock icon ring) is blue; the Electron app's stays purple | Anup, 2026-10-09: with both icons following a purple accent he couldn't tell the apps apart in the Dock. Each app's default differs; the user can still pick any accent in Settings. |
| 15 | Metronome bars come from a pure generator (`MetronomePattern.events`); the scheduler places each event relative to the previous one at the current tempo and asks the trainers only at bar boundaries; per-role gains are baked into the buffers; BPM counts the time signature's note value (7/8 at 120 = 120 eighths); swing 100% = triplet feel; subdivision ticks still sound under a muted beat cell, only a gap-muted bar silences them; the tempo trainer returns to its start tempo on Stop | Testable without audio, no drift, the old `player.volume`-per-beat trick applied to everything already queued; off-beat practice needs subs under muted beats |
| 16 | Device settings writes (type 67) carry LED brightness and USB volume together, are sent only after a successful 65/66 read, one at a time with the latest value queued; only those two fields are writable, the rest of 66 is shown read-only | The phone app writes both fields every time, so an unread value would overwrite the pedal's; the other fields' meanings are unverified (PROTOCOL-NOTES §13) |
| 17 | Preset tempo: live writes (145 scope 1) while a control moves, one preset write (scope 0, preceded by a live write with the same value) when it settles, Save commits; field 4 always 0. The metronome's "Follow the preset tempo" is off by default; when on and connected it mirrors the preset tempo and writes its changes back (trainer steps live only) | Same sequence as the official app (trace 2026-10-09), so the pedal never sees an unfamiliar order; a preset write marks the preset edited, which a practice metronome shouldn't do unless asked |
| 18 | Expression records go out in ascending field order (upstream emits its own list order: gain, bass, mid, treble, level, gate, then the FX amounts); an empty bypass record reads as heel-toe 600 ms; heel/toe show capture volume in dB and the rest as % of 0–255 | Canonical protobuf order is what the official app's serializer most likely writes and is identical to upstream for every set in the trace; upstream shows everything as %, but the panel should speak the parameter's units like the inspector. Both unverified on the pedal (PROTOCOL-NOTES §12) |

## Deferred ideas
- SwiftProtobuf with hand-written `.proto` files, if the message set grows large.

## Rejected
- Porting before the protocol was hardware-verified (the Electron app did that first, on purpose).
