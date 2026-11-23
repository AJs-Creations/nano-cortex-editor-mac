# AI assistants (MCP): protocol and shared behaviour

The contract both Nano Cortex editors implement for AI assistants (Model Context Protocol). **Source of truth:** this
folder in the Electron repo (`nano-cortex-editor/mcp/`). The native repo keeps a verbatim copy of the whole folder
(`nano-cortex-editor-mac/mcp/`, refreshed by its `scripts/sync-mcp.js`, checked by `scripts/sync-mcp.js --check`).
Change it here first, copy it, then implement the change in both editors (feature parity).

| File | What |
| --- | --- |
| `tools.json` | Server name, instructions, the `build_tone` prompt, error texts, loudness limits, and all 30 tools (name, kind, title, description, input schema). |
| `helper.js`, `endpoint.js` | The Electron edition's MCP helper (stdio), and the socket/token rules it shares with `src/mcp-server.js`. Also the body of the Claude Desktop `.mcpb` bundle, which works with either edition. |
| `conformance.js` | The helper test. `node mcp/conformance.js` (this helper) or `node mcp/conformance.js -- <native helper binary>`. Both must pass it. |
| `PROTOCOL.md` | This file. |

Background, decisions and the original plan: `mac_projects/MCP-PLAN.md` (outside the repos), DECISIONS #43–#48 in
the native repo, `docs/HANDOFF.md` in the Electron repo.

```
assistant app ──stdio (MCP)──▶ helper ──private local socket + token──▶ the running editor ──Bluetooth──▶ pedal
```

## 1. The socket

- **Path** (the same for both editions, so the one name `nano-cortex` reaches whichever editor runs):
  macOS and Linux `/tmp/nano-cortex-<uid>/editor.sock`; Windows the named pipe `\\.\pipe\nano-cortex-<username>`.
  `NANO_MCP_DIR` overrides the folder (tests only; the editor and the helper both honour it).
- **The folder** must be a real directory owned by this user with mode `0700`. The editor creates it with `0700`
  when missing. Both sides refuse a folder that is a symlink, belongs to another user or is readable by others
  (`checkPrivateDir`); the editor then does not listen and Settings shows why.
- **The token**: when the editor starts listening it writes 64 random hex characters to `<folder>/token` with mode
  `0600` (write a temporary file, then rename). The helper reads it fresh on every connect.
- **Only when switched on**: the editor listens only while Settings → AI assistants is on (off by default; the
  setting survives relaunches). Turning it off, or quitting, closes every connection and removes `editor.sock` and
  `token`.
- **One editor at a time**: before listening, the editor tries to connect to an existing `editor.sock`. If something
  answers, another editor (either edition) is serving: do not take over; Settings shows "Another Nano Cortex Editor
  is already serving AI assistants." and retries every 5 s. If nothing answers, unlink the stale file and listen.

## 2. Messages

One JSON object per line (UTF-8, `\n`), at most 1 MiB per line; a longer or malformed line closes the connection.

1. helper → editor, first line: `{"type":"hello","token":"<64 hex>","contract":1,"client":{"name":"claude-code","version":"2.1.0"}}`
   (`client` is the assistant's `clientInfo` from MCP `initialize`).
2. editor → helper: `{"type":"hello","ok":true,"editor":{"name":"Nano Cortex Editor","edition":"electron"|"native","version":"1.3.0","contract":1}}`,
   or `{"type":"hello","ok":false,"error":"<why>"}` and the editor closes the connection. Refuse when the token is
   wrong (compare in constant time) or `contract` differs from `tools.json`'s `contractVersion` (error: "This
   assistant's setup is from another version of Nano Cortex Editor. Copy the setup line again from Settings → AI
   assistants."). Nothing but a hello is accepted before a successful hello.
3. helper → editor: `{"type":"call","id":<int>,"tool":"set_amp","args":{…}}`
4. editor → helper: `{"type":"result","id":<same>,"ok":true,"result":{…}}` or `{"type":"result","id":<same>,"ok":false,"error":"<text for the assistant>"}`

The helper keeps one connection and reconnects lazily on the next call after the editor went away. A call that is
still open when the connection closes fails. Helper timeouts: confirmation tools 10 min, `get_slot_usage` with
`scan` 5 min, `cloud_preview` 3 min, anything else 2 min.

## 3. The helper (MCP side)

stdio, JSON-RPC 2.0, one message per line; never writes anything but protocol messages to stdout.

- `initialize`: echoes the client's `protocolVersion` when it is one of `2025-11-25`, `2025-06-18`, `2025-03-26`,
  `2024-11-05`, else answers `2025-11-25`; capabilities `tools` and `prompts` (`listChanged: false`);
  `serverInfo` `{ name: "nano-cortex", title: "Nano Cortex Editor", version: <the app's version> }`;
  `instructions` = `server.instructions`.
- `tools/list`: every tool of `tools.json`, in order, with `$ref`s inlined from `$defs` and these annotations:
  `readOnlyHint` for kind `read` plus `cloud_search` and `cloud_open`; `destructiveHint` for kind `confirm` and
  tools with `"destructive": true`; `idempotentHint` = `readOnlyHint`; `openWorldHint` for kind `cloud` and
  `cloud_send`; `title`.
- `tools/call`: an unknown tool name is JSON-RPC error `-32602`. Otherwise forward to the editor (`arguments`
  missing → `{}`). `ok:true` → `content: [{type:"text", text: JSON of the result, 2-space indent}]` plus
  `structuredContent` (the result object). `ok:false`, no editor, or a refused hello → `isError: true` with the
  text: `errors.editorNotRunning` when there is no folder, no token or nothing listening.
- `prompts/list`, `prompts/get` (fills `{request}` into `template`; a missing required argument is `-32602`),
  `ping`. Notifications are ignored; any other request is `-32601`. Exits when stdin closes.
- **It never launches the editor.**

## 4. The editor side (both editions)

### Validation and order
- Validate `args` against the tool's schema (types, enums, ranges, required, no unknown keys) and refuse with a
  sentence naming the field ("slot must be one of pre1, pre2, post1, post2, post3."). Effect model and parameter
  names match case-insensitively; a switch parameter takes its option text (case-insensitive) or its index.
- Calls run **one at a time**, across all connections, in arrival order (a confirmation dialog holds the queue).
- Every tool except `get_status` and the `cloud_*` tools needs a connected pedal: else `errors.notConnected`.
  While a capture transfer, an IR transfer, a slot scan or a modal dialog of the user's own is running, live and
  confirm tools answer `errors.busy`.
- **`apply_tone` validates everything first** (every name, range and loudness step) and changes nothing when
  any part is refused; then it applies in the documented order, waits for the pedal to report the state back (a
  state read, as after a model change; at most ~3 s), and returns `{ changes: [lines], preset: <get_current_preset> }`.

### Loudness limits (`tools.json` → `safety`)
Compared with the value **before the call** (for `apply_tone`, before the whole call):
- amp `level`: at most +`ampLevelStep` (2.0 of 10) per call;
- `volume_db` (capture volume): at most +`captureVolumeDbStep` (6 dB) per call and never above
  `captureVolumeDbMax` (+6 dB);
- cab `level_db`: at most +`cabLevelDbStep` (6 dB) per call and never above `cabLevelDbMax` (+6 dB);
- an effect parameter whose name matches `effectLevelParams` (case-insensitive) and has a numeric range: at most
  +`effectLevelStepShare` (a quarter) of its range per call.
A refusal uses `stepRefusal` / `maxRefusal` with `{what}` ("Level", "volume_db", "cab level_db", "Post FX 3
Mix"), `{step}` ("2", "6 dB", "25 % of its range") and `{max}` ("+6 dB"). A value already above a cap may stay or
go down.

### Confirmation tools (`kind: "confirm"`)
The editor shows **its own** dialog (the existing Save as / Rename dialogs where they exist, prefilled from `args`;
otherwise a dialog in the editor's style) and waits. The dialog says the assistant asked: a first line "Asked by
<client name>." (the hello's `client.name`, or "your AI assistant"). The editor window comes to the front
(un-minimised) when such a dialog opens. Cancel, Escape or closing → `ok:false` with `errors.cancelled`. The
confirming click runs exactly the path the user's own click would (audition gate, unsaved-changes prompt for a
footswitch assignment, …).

| Tool | Dialog | Result |
| --- | --- | --- |
| `save` | "Save changes to preset N “Name”?" · Cancel / **Save** | `{ saved: true, number, name }` |
| `save_as` | the Save as dialog with `name` and `number` preselected (no `number`: the editor's usual first empty preset) | `{ saved: true, number, name }` as the user left them |
| `rename` | the Rename dialog with `name` | `{ renamed: true, number, name }` |
| `load_capture_into_slot`, `load_cab_into_slot` | "Load “X” into capture slot N?" naming what the slot holds now and, when known from the last scan, which presets use it · Cancel / **Load** | `{ loaded: true, slot, name }` |
| `set_cab_mic` | "Change the mic of cab slot N?" with old → new mic and position · Cancel / **Change** | `{ mic, position }` |
| `assign_footswitch` | "Assign preset N “Name” to footswitch IA?" · Cancel / **Assign** (then the editor's own unsaved-edits prompt if needed) | `{ assigned: true, footswitch, preset }` |
| `cloud_send` | the editor's existing Send confirmation for that capture | `{ sent: true, name }` |

### Results (field names shared by both editions)
- `get_status`: `{ editor: { edition, version }, connected, pedal: { name, firmware } | null, preset: { number, name, unsaved } | null, audition: { kind: "capture"|"cab", name } | null, cloud: { signedIn: true|false|null }, assistants: { clients: [names] } }`
- `get_current_preset`: `{ number, name, unsaved, amp: { gain, bass, mid, treble, level, volume_db }, capture: { on, slot, name, fromLibrary }, cab: { on, slot, name, factory, mic, position, mics: [names], level_db, high_pass_hz, low_pass_hz, fromLibrary }, gate: { on, reduction }, effects: [ { slot, title, on, model, category, known, params: [ { name, value, display, unit, min, max, step } | { name, value: "<option>", options: [..] } ], valuesKnown } ], tempo: { bpm } }`.
  Amp knobs are 0–10 with one decimal (raw / 25.5). `slot` is null when the preset plays from the library.
  `valuesKnown: false` when the editor has not read that effect's parameters (values are then the defaults).
- `list_presets`: `{ current, presets: [ { number, name, empty } ×64 ], footswitches: { IA, IB, IIA, IIB } }` (preset numbers or null).
- `list_library`: `{ kind, slots: [ { slot, name } ], library: [ { source: "factory"|"user", name, type, instrument, description } ] }` (cab items have no type/instrument; `description` only where the pedal gives one).
- `list_effects`: `{ slots: [ { slot, title, models: [ { name, category, params: [ { name, unit, min, max, step } | { name, options } ] } ] } ] }` ("None" is not listed; it is always allowed).
- `get_slot_usage`: `{ scanned: bool, capture: { "<slot>": [preset numbers] }, cab: { "<slot>": [preset numbers] } }`.
- Single live tools: `{ summary: "<the Activity line without the prefix>", ... the new values }`.
- `cloud_search`: `{ query, page, pages, total, results: [ { product_id, name, author, tags, instrument, device, gain, downloads, likes, description (≤ 300 chars), onPedal } ] }`.

### What the user sees
- **Settings → AI assistants** (a new page / section; the texts are the same in both editions):
  - switch **"Allow AI assistants to control the editor"** (off by default) with the line "Assistants on this
    computer, such as Claude, ChatGPT or Codex, can read the pedal and make live edits. Saving and anything stored on
    the pedal still needs your click in the editor.";
  - a status line: "Off" · "On, waiting for an assistant" · "Connected: Claude Code" (names of the connected
    clients) · or the reason it cannot listen;
  - **Set up** rows, each with the exact text and a **Copy** button (and a **Learn more** link to that assistant's
    official MCP page): Claude Code (`claude mcp add -s user nano-cortex …`), Codex and the ChatGPT desktop app
    (`codex mcp add nano-cortex …`), Claude Desktop (**Add to Claude Desktop…**: shows the entry it will write to
    `claude_desktop_config.json` and asks first; keeps every other entry), Cursor and VS Code (install links), and
    "Other assistants" (the JSON entry). The paths are this installation's.
  - Learn more links: Claude Code <https://code.claude.com/docs/en/mcp>, Codex <https://developers.openai.com/codex/mcp>,
    Claude Desktop <https://modelcontextprotocol.io/docs/develop/connect-local-servers>, Cursor
    <https://cursor.com/docs/context/mcp>, VS Code <https://code.visualstudio.com/docs/copilot/customization/mcp-servers>.
- **Status bar**: while at least one assistant is connected, a small pill "Assistant" (accent colour) with the
  client names as its tooltip; clicking it opens Settings → AI assistants.
- **Activity log**: one line per call, `Assistant: <summary>` (for example `Assistant: Post FX 3 Mix → 25 %`,
  `Assistant: amp Gain 4.5, Level 6.0`, `Assistant: refused set_amp: Raise Level in smaller steps …`). Reads log
  once per call (`Assistant: read the current preset`).
- No toasts for live edits (the UI just updates, as for a knob turn); a toast when a connection opens ("Claude Code
  connected") and for a refusal the user should know about (unsaved edits on `select_preset`).

### Setup lines (`<exe>`, `<helper>` are this installation's paths)
- Electron: `<exe>` = the app executable, `<helper>` = `<resources>/app.asar.unpacked/mcp/helper.js` (from source:
  the Electron binary and `<repo>/mcp/helper.js`), environment `ELECTRON_RUN_AS_NODE=1`.
  - Claude Code: `claude mcp add -s user -e ELECTRON_RUN_AS_NODE=1 nano-cortex -- "<exe>" "<helper>"`
  - Codex: `codex mcp add nano-cortex --env ELECTRON_RUN_AS_NODE=1 -- "<exe>" "<helper>"`
  - JSON: `{"mcpServers":{"nano-cortex":{"command":"<exe>","args":["<helper>"],"env":{"ELECTRON_RUN_AS_NODE":"1"}}}}`
- Native: `<helper>` = `<app>/Contents/Helpers/nano-cortex-mcp`, no environment.
  - Claude Code: `claude mcp add -s user nano-cortex -- "<helper>"`
  - Codex: `codex mcp add nano-cortex -- "<helper>"`
  - JSON: `{"mcpServers":{"nano-cortex":{"command":"<helper>"}}}`
- Cursor: `cursor://anysphere.cursor-deeplink/mcp/install?name=nano-cortex&config=<base64 of {"command":…,"args":[…],"env":{…}}>`;
  VS Code: `vscode:mcp/install?<URL-encoded {"name":"nano-cortex","command":…,"args":[…],"env":{…}}>`.
- Claude Desktop config file: macOS `~/Library/Application Support/Claude/claude_desktop_config.json`, Windows
  `%APPDATA%\Claude\claude_desktop_config.json` (no Linux build of Claude Desktop: hide the row there).

### Never
- No tool that runs code, sends raw packets, reads or writes files, or reaches the dev remote.
- No tool stores anything on the pedal without the dialog. No `confirm` argument in the chat.
- No secrets in the assistants' config files (the token lives only in the private folder).
