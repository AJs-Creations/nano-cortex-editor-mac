#!/usr/bin/env node
'use strict';

// AI assistants end to end, through the REAL path (mcp/PROTOCOL.md): this script is the assistant app. It spawns the
// built helper (Contents/Helpers/nano-cortex-mcp), speaks MCP to it over stdio, and the helper talks to a running
// Debug build over the private socket; the editor's dev remote (Debug only) checks what happened on the demo pedal and
// answers the confirmation dialogs (/agent?dialog=confirm|cancel). Demo mode only: it never touches a real pedal.
//
//   open -n -g -j --env NANO_DEV_PORT=4850 --env NANO_MCP_DIR=/tmp/ncmcp-check "build/Build/Products/Debug/Nano Cortex Editor.app" \
//        --args -demo -connect.atLaunch NO -ApplePersistenceIgnoreState YES -ai.enabled YES -ai.noActivate YES
//   curl -s http://127.0.0.1:4850/demo
//   NANO_MCP_DIR=/tmp/ncmcp-check node scripts/mcp-demo-check.js [--port 4850] [--helper <path>]
//
// Without NANO_MCP_DIR both sides use the real /tmp/nano-cortex-<uid> folder. Calls every tool at least once, every
// refusal kind, and each confirmation tool once cancelled and once confirmed. Exit code 0 when every check passes.

const { spawn } = require('child_process');
const http = require('http');
const path = require('path');

const argv = process.argv.slice(2);
const opt = (name, dflt) => { const i = argv.indexOf('--' + name); return i >= 0 ? argv[i + 1] : dflt; };
const PORT = Number(opt('port', '4850'));
const HELPER = opt('helper', path.join(__dirname, '..', 'build/Build/Products/Debug/Nano Cortex Editor.app/Contents/Helpers/nano-cortex-mcp'));

let passed = 0, failed = 0;
const failures = [];
function check(name, ok, detail) {
  if (ok) { passed++; console.log('  ok   ' + name); return; }
  failed++; failures.push(name);
  console.log('  FAIL ' + name + (detail !== undefined ? '\n       ' + JSON.stringify(detail).slice(0, 700) : ''));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------ the dev remote

function remote(target) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: PORT, path: target, timeout: 60000 }, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => { try { resolve(JSON.parse(body)); } catch { resolve({ raw: body }); } });
    }).on('error', reject);
  });
}

// ------------------------------------------------------------------ the helper, as an assistant app would run it

const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;
const child = spawn(HELPER, [], { env, stdio: ['pipe', 'pipe', 'pipe'] });
let stderr = '';
child.stderr.on('data', (d) => { stderr += d; });
const waiting = new Map();
let nextId = 1, buf = '';
child.stdout.on('data', (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let msg; try { msg = JSON.parse(line); } catch { stderr += '[not JSON on stdout] ' + line + '\n'; continue; }
    if (waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
  }
});
function rpc(method, params, ms = 120000) {
  return new Promise((resolve) => {
    const id = nextId++;
    const t = setTimeout(() => { waiting.delete(id); resolve({ timeout: true }); }, ms);
    waiting.set(id, (m) => { clearTimeout(t); resolve(m); });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}
/** tools/call → { ok, result | error } */
async function call(name, args = {}, ms) {
  const r = await rpc('tools/call', { name, arguments: args }, ms);
  if (r.error) return { ok: false, rpcError: r.error };
  if (!r.result) return { ok: false, error: 'no answer', raw: r };
  const text = r.result.content && r.result.content[0] && r.result.content[0].text;
  return r.result.isError ? { ok: false, error: text } : { ok: true, result: r.result.structuredContent, text };
}
async function waitDialog(ms = 8000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const s = await remote('/agent?status=1');
    if (s.dialog) return s.dialog;
    await sleep(100);
  }
  return null;
}
/** A confirmation tool: the call stays open until /agent?dialog=<answer>. */
async function confirmFlow(name, args, answer) {
  const pending = call(name, args, 600000);
  const dialog = await waitDialog();
  const a = await remote('/agent?dialog=' + answer);
  return { dialog, answered: a, r: await pending };
}
const state = () => remote('/state');
const ui = () => remote('/ui');

// ------------------------------------------------------------------ the run

(async () => {
  console.log('MCP demo check: ' + HELPER + ' → editor (dev remote :' + PORT + ', NANO_MCP_DIR=' + (process.env.NANO_MCP_DIR || 'unset') + ')');
  const contract = require('../mcp/tools.json');
  const errors = contract.errors;
  const messages = contract.messages;
  const fill = (text, vals) => text.replace(/\{(\w+)\}/g, (_, k) => String(vals[k]));

  let r = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'claude-code', version: 'demo-check' } });
  check('initialize: nano-cortex, the app version', r.result && r.result.serverInfo.name === 'nano-cortex' && /^\d+\.\d+\.\d+$/.test(r.result.serverInfo.version), r.result && r.result.serverInfo);
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  r = await rpc('tools/list', {});
  check('tools/list: 30 tools', r.result && r.result.tools.length === 30, r.result && r.result.tools.length);
  r = await rpc('tools/call', { name: 'no_such_tool', arguments: {} });
  check('unknown tool: JSON-RPC -32602 (helper)', r.error && r.error.code === -32602, r);

  const ag = await remote('/agent?status=1');
  check('editor is listening (status waiting, socket and token exist)', ag.status === 'waiting' && ag.socketExists && ag.tokenExists, ag);

  // ---- reads
  let s = await call('get_status');
  check('get_status: connected, native edition', s.ok && s.result.connected === true && s.result.editor.edition === 'native' && s.result.pedal, s);
  check('get_status: the connection is listed as Claude Code', s.ok && s.result.assistants.clients.includes('Claude Code'), s.result && s.result.assistants);
  const st0 = await remote('/agent?status=1');
  check('Settings status line: messages.statusConnected ("Connected: Claude Code")', st0.statusText === fill(messages.statusConnected, { clients: 'Claude Code' }), st0.statusText);
  const pre0 = await call('get_current_preset');
  check('get_current_preset: amp, capture, cab, gate, 5 effects, tempo', pre0.ok && pre0.result.amp && pre0.result.capture && pre0.result.cab && pre0.result.gate && pre0.result.effects.length === 5 && pre0.result.tempo, pre0);
  const presets = await call('list_presets');
  check('list_presets: 64 and the footswitches', presets.ok && presets.result.presets.length === 64 && 'IA' in presets.result.footswitches, presets.result && presets.result.footswitches);
  const caps = await call('list_library', { kind: 'capture' });
  check('list_library capture: slots and library', caps.ok && caps.result.slots.length >= 25 && caps.result.library.length > 0, caps.result && { slots: caps.result.slots.length, lib: caps.result.library.length });
  const cabs = await call('list_library', { kind: 'cab' });
  check('list_library cab', cabs.ok && cabs.result.slots.length >= 5 && cabs.result.library.length > 0, cabs.result && { slots: cabs.result.slots.length, lib: cabs.result.library.length });
  r = await call('list_library', { kind: 'capture', instrument: 'bass' });
  check('list_library filters (instrument bass)', r.ok && r.result.library.every((c) => c.instrument === 'bass'), r.result && r.result.library.slice(0, 3));
  r = await call('list_effects');
  check('list_effects: five slots, no Pitch in pre2', r.ok && r.result.slots.length === 5 && !r.result.slots[1].models.some((m) => m.category === 'Pitch'), r.ok && r.result.slots.map((x) => x.models.length));
  r = await call('list_effects', { slot: 'post3' });
  check('list_effects slot=post3', r.ok && r.result.slots.length === 1 && r.result.slots[0].models.some((m) => m.name === 'Room'), r);
  r = await call('get_slot_usage');
  check('get_slot_usage (no scan)', r.ok && typeof r.result.scanned === 'boolean', r);

  // ---- apply_tone
  const capSlot = caps.result.slots.find((x) => x.name && x.slot !== pre0.result.capture.slot) || caps.result.slots[0];
  const cabSlot = cabs.result.slots.find((x) => x.name) || cabs.result.slots[0];
  const level0 = pre0.result.amp.level;
  const tone = { capture_slot: capSlot.slot, cab_slot: cabSlot.slot, amp: { gain: 4.5, level: Math.min(10, Math.round((level0 + 1) * 10) / 10) }, gate: { on: true, reduction: 30 },
    cab_tone: { level_db: Math.round(pre0.result.cab.level_db + 3), high_pass_hz: 90 }, effects: [{ slot: 'post3', model: 'Room', params: { Mix: 30, decay: 1.5 }, on: true }, { slot: 'post1', model: 'chorus 229t', params: { Sync: 'On' }, on: false }] };
  r = await call('apply_tone', tone);
  check('apply_tone: ok, one line per change, the preset read back', r.ok && r.result.changes.length >= 8 && r.result.preset && r.result.preset.effects[4].model === 'Room', r);
  await sleep(600);
  let st = await state(), u = await ui();
  check('apply_tone on the pedal: gain raw 115, capture/cab slots', st.gain === 115 && st.captureSlot === capSlot.slot && st.cabSlot === cabSlot.slot, { gain: st.gain, captureSlot: st.captureSlot, cabSlot: st.cabSlot });
  check('apply_tone on the pedal: Post FX 3 Room (C03E) on, Post FX 1 Chorus 229T (EF36) off', st.fx.post3.model === 'C03E' && st.fx.post3.on === true && st.fx.post1.model === 'EF36' && st.fx.post1.on === false, st.fx);
  check('apply_tone in the editor: Room Mix 30, Decay 1.5; gate 30 %; cab HPF 90', u.blocks.post3.model === 'Room' && u.blocks.post3.values[0] === 30 && u.blocks.post3.values[1] === 1.5 && u.gate === 30 && u.cab.hpf === 90, { post3: u.blocks.post3, gate: u.gate, hpf: u.cab.hpf });
  // Review #3: a model change in apply_tone reads its values once, after its writes; never a read of a block it turned off.
  r = await call('apply_tone', { effects: [{ slot: 'post3', model: 'Mind Hall', on: false }] });
  let hooks = await remote('/fakehooks');
  check('apply_tone: a new model turned off in the same call is never read while bypassed', r.ok && hooks.bypassedReads === 0, { r: r.ok, hooks });
  r = await call('apply_tone', { effects: [{ slot: 'post3', model: 'Room', params: { Mix: 30, decay: 1.5 }, on: true }] });
  u = await ui();
  check('apply_tone: the new model\'s values are read back (known, Mix 30)', r.ok && u.blocks.post3.known === true && u.blocks.post3.values[0] === 30, { r: r.ok, post3: u.blocks.post3 });
  // Review #2: a level_db step for another cab slot can't be checked against a level the editor never read.
  const otherCab = cabs.result.slots.find((x) => x.name && x.slot !== cabSlot.slot);
  if (otherCab) {
    r = await call('apply_tone', { cab_slot: otherCab.slot, cab_tone: { level_db: 6 } });
    st = await state();
    check('apply_tone: level_db with another cab slot is refused (unread level), nothing changed', !r.ok && /has not read the level/.test(r.error) && st.cabSlot === cabSlot.slot, { r, cabSlot: st.cabSlot });
  }
  r = await call('apply_tone', { amp: { gain: 2 }, effects: [{ slot: 'post2', model: 'Hall' }] });
  st = await state();
  check('apply_tone refused part → nothing changed (gain stays 115)', !r.ok && /no effect named/.test(r.error) && st.gain === 115, { r, gain: st.gain });

  // ---- single live tools and the refusals
  r = await call('set_amp', { gain: 6 });
  await sleep(300); await remote('/reread'); await sleep(500); st = await state();   // the demo pedal reports what it got
  check('set_amp gain 6 → raw 153, summary', r.ok && r.result.summary === 'amp Gain 6.0' && st.gain === 153, { r, gain: st.gain });
  const lvl = r.result.amp.level;
  r = await call('set_amp', { level: Math.min(10, lvl + 2.5) });
  check('loudness step: amp Level +2.5 refused', !r.ok && r.error === contract.safety.stepRefusal.replace('{what}', 'Level').replace('{step}', '2'), r);
  r = await call('set_amp', { volume_db: 9 });
  check('loudness max: volume_db 9 refused', !r.ok && r.error === contract.safety.maxRefusal.replace('{what}', 'volume_db').replace('{max}', '+6 dB'), r);
  r = await call('set_effect', { slot: 'pre1', model: 'Green 808', on: true });
  await sleep(500); u = await ui();
  check('set_effect pre1 Green 808 on', r.ok && r.result.model === 'Green 808' && u.blocks.pre1.model === 'Green 808' && u.blocks.pre1.on, { r, pre1: u.blocks.pre1 });
  r = await call('set_effect', { slot: 'pre2', model: 'Transpose' });
  check('unknown model: Transpose in Pre FX 2 refused', !r.ok && /Pre FX 2 has no effect named/.test(r.error), r);
  r = await call('set_effect_param', { slot: 'pre1', param: 'tone', value: 7 });
  await sleep(300); u = await ui();
  check('set_effect_param pre1 Tone 7', r.ok && r.result.display === '7' && u.blocks.pre1.values[1] === 7, { r, values: u.blocks.pre1.values });
  r = await call('set_effect_param', { slot: 'pre1', param: 'Bogus', value: 1 });
  check('unknown parameter refused', !r.ok && /has no parameter “Bogus”/.test(r.error), r);
  const lv = u.blocks.pre1.values[2];
  r = await call('set_effect_param', { slot: 'pre1', param: 'Level', value: Math.min(100, lv + 40) });
  check('loudness step: an effect Level +40 % refused', !r.ok && /Raise Pre FX 1 Level in smaller steps \(at most 25 % of its range per call\)/.test(r.error), r);
  r = await call('set_effect', { slot: 'pre3' });
  check('validation: the sentence names the field', !r.ok && r.error === 'slot must be one of pre1, pre2, post1, post2, post3.', r);
  r = await call('set_gate', { on: false, reduction: 40 });
  await sleep(300); u = await ui();
  check('set_gate off, 40 %', r.ok && u.gateOn === false && u.gate === 40, { r, gateOn: u.gateOn, gate: u.gate });
  r = await call('set_cab_tone', { high_pass_hz: 100, low_pass_hz: 9000 });
  await sleep(300); u = await ui();
  check('set_cab_tone HPF 100, LPF 9000', r.ok && u.cab.hpf === 100 && u.cab.lpf === 9000, { r, cab: u.cab });
  r = await call('set_cab_tone', { level_db: 7 });
  check('loudness max: cab level_db 7 refused', !r.ok && /cab level_db is limited to \+6 dB/.test(r.error), r);
  const capSlot2 = caps.result.slots.find((x) => x.name && x.slot !== capSlot.slot);
  r = await call('use_capture_slot', { slot: capSlot2.slot });
  st = await state();
  check('use_capture_slot', r.ok && st.captureSlot === capSlot2.slot, { r, captureSlot: st.captureSlot });
  r = await call('use_cab_slot', { on: false });
  st = await state();
  check('use_cab_slot off', r.ok && st.cabSlot === 0, { r, cabSlot: st.cabSlot });
  r = await call('use_cab_slot', { slot: cabSlot.slot });
  st = await state();
  check('use_cab_slot back on', r.ok && st.cabSlot === cabSlot.slot, { r, cabSlot: st.cabSlot });
  r = await call('use_cab_slot', { slot: cabSlot.slot, on: false });
  check('use_cab_slot with slot and on:false: messages.slotOrOff', !r.ok && r.error === messages.slotOrOff, r);
  r = await call('use_capture_slot', { slot: caps.result.slots.length + 1 });
  check('use_capture_slot above the pedal\'s slots: messages.captureSlotRange', !r.ok && r.error === fill(messages.captureSlotRange, { field: 'slot', count: caps.result.slots.length }), r);
  r = await call('apply_tone', { cab_slot: cabs.result.slots.length + 1 });
  check('apply_tone cab_slot above the pedal\'s slots: messages.cabSlotRange', !r.ok && r.error === fill(messages.cabSlotRange, { field: 'cab_slot', count: cabs.result.slots.length }), r);
  r = await call('set_tempo', { bpm: 128 });
  st = await state();
  check('set_tempo 128', r.ok && r.result.tempo.bpm === 128 && st.presetTempo === 128, { r, presetTempo: st.presetTempo });
  r = await call('set_tempo', { bpm: 250 });
  check('set_tempo 250 on NanOS 2.3 (40–240): messages.tempoRange', !r.ok && r.error === fill(messages.tempoRange, { min: 40, max: 240 }), r);
  r = await call('set_tempo', { bpm: 120.46 });
  check('set_tempo keeps one decimal on NanOS 2.3 (120.5)', r.ok && r.result.tempo.bpm === 120.5, r);
  const target = presets.result.current === 3 ? 4 : 3;
  r = await call('select_preset', { number: target });
  check('unsaved edits: select_preset refused', !r.ok && r.error === errors.unsavedEdits, r);
  r = await call('discard_edits');
  st = await state();
  check('discard_edits', r.ok && st.edited === false, { r, edited: st.edited });
  r = await call('save');
  check('save with no unsaved edits: messages.nothingToSave', !r.ok && r.error === fill(messages.nothingToSave, { number: st.presetIndex + 1 }), r);
  r = await call('select_preset', { number: target });
  st = await state();
  check('select_preset ' + target, r.ok && st.presetIndex === target - 1, { r, presetIndex: st.presetIndex });
  const factoryCab = cabs.result.library.find((c) => c.source === 'factory');
  r = await call('preview_cab', { source: 'factory', name: factoryCab.name });
  let au = await remote('/audition');
  check('preview_cab ' + factoryCab.name, r.ok && au.ir.active && au.ir.active.includes(factoryCab.name), { r, ir: au.ir });
  r = await call('stop_preview');
  au = await remote('/audition');
  check('stop_preview', r.ok && r.result.stopped === true && !au.ir.active, { r, ir: au.ir });

  // ---- busy
  await remote('/saveassheet?on=1');
  r = await call('set_amp', { gain: 5 });
  check('busy: a dialog of the user\'s own is open → errors.busy', !r.ok && r.error === errors.busy, r);
  await remote('/saveassheet?on=0');
  await remote('/shortcuts?on=1');
  r = await call('set_amp', { gain: 5 });
  check('busy: the Keyboard Shortcuts sheet counts too (review #6)', !r.ok && r.error === errors.busy, r);
  await remote('/shortcuts?on=0');

  // ---- Cortex Cloud (demo mode's three made-up captures)
  r = await call('cloud_search', { query: 'clean' });
  check('cloud_search (demo set)', r.ok && r.result.results.length === 3 && r.result.results[0].product_id && r.result.query === 'clean', r);
  const pid = r.ok && r.result.results[0].product_id;
  r = await call('cloud_open', { product_id: pid });
  const cl = await remote('/cloud');
  check('cloud_open: the Cloud tab on that page', r.ok && (await ui()).tab === 'cloud' && (cl.url || '').includes(pid), { r, url: cl.url });
  await remote('/tab?t=editor');
  r = await call('cloud_preview', { product_id: pid }, 180000);
  au = await remote('/audition');
  check('cloud_preview: Live Preview playing', r.ok && au.capture.phase === 'active', { r, capture: au.capture });
  r = await call('stop_preview');
  check('stop_preview ends the Live Preview', r.ok && r.result.stopped === true, r);

  // ---- confirmations: each once cancelled, once confirmed
  await call('set_amp', { gain: 5.5 });
  let f = await confirmFlow('save', {}, 'cancel');
  check('save: the dialog ("Save changes to preset …?", asked by Claude Code)', f.dialog && /^Save changes to preset \d+ “/.test(f.dialog.title) && f.dialog.askedBy === 'Claude Code', f.dialog);
  check('save cancelled → errors.cancelled, still unsaved', !f.r.ok && f.r.error === errors.cancelled && (await state()).edited === true, f.r);
  f = await confirmFlow('save', {}, 'confirm');
  st = await state();
  check('save confirmed → saved, clean', f.r.ok && f.r.result.saved === true && st.edited === false, { r: f.r, edited: st.edited });

  const empty = presets.result.presets.find((p) => p.empty && p.number !== target);
  f = await confirmFlow('save_as', { name: 'Assistant Test', number: empty.number }, 'cancel');
  check('save_as: the Save as dialog prefilled', f.dialog && f.dialog.kind === 'saveAs' && f.dialog.number === empty.number && f.dialog.name === 'Assistant Test', f.dialog);
  check('save_as cancelled', !f.r.ok && f.r.error === errors.cancelled, f.r);
  r = await call('save_as', { name: '   ab   ', number: empty.number });
  check('save_as: a name the dialog would refuse is refused first (no dialog)', !r.ok && /at least 4 characters/.test(r.error) && !(await remote('/agent?status=1')).dialog, r);
  // The answer comes once the pedal is on the new preset (review #4): no wait before reading it.
  f = await confirmFlow('save_as', { name: 'Assistant Test', number: empty.number }, 'confirm');
  st = await state();
  check('save_as confirmed → preset ' + empty.number + ' "Assistant Test", now loaded', f.r.ok && f.r.result.number === empty.number && st.presets[empty.number - 1] === 'Assistant Test' && st.presetIndex === empty.number - 1, { r: f.r, name: st.presets[empty.number - 1], presetIndex: st.presetIndex });

  r = await call('rename', { name: '   a   ' });
  check('rename: "   a   " refused before the dialog (review #10)', !r.ok && /at least 4 characters/.test(r.error) && !(await remote('/agent?status=1')).dialog, r);
  f = await confirmFlow('rename', { name: 'Renamed By Test' }, 'cancel');
  check('rename: the Rename dialog prefilled; cancelled', f.dialog && f.dialog.kind === 'rename' && f.dialog.name === 'Renamed By Test' && !f.r.ok && f.r.error === errors.cancelled, f);
  f = await confirmFlow('rename', { name: 'Renamed By Test' }, 'confirm');
  st = await state();
  check('rename confirmed', f.r.ok && f.r.result.name === 'Renamed By Test' && st.presets[st.presetIndex] === 'Renamed By Test', { r: f.r, name: st.presets[st.presetIndex] });

  const libCap = caps.result.library.find((c) => c.source === 'factory' && c.name !== st.captures[2]);
  f = await confirmFlow('load_capture_into_slot', { source: 'factory', name: libCap.name, slot: 3 }, 'cancel');
  check('load_capture_into_slot: the dialog names the slot and what it holds; cancelled', f.dialog && f.dialog.title === `Load “${libCap.name}” into capture slot 3?` && /slot 3 (holds|is empty)/.test(f.dialog.lines[0]) && !f.r.ok, f);
  f = await confirmFlow('load_capture_into_slot', { source: 'factory', name: libCap.name, slot: 3 }, 'confirm');
  st = await state();
  check('load_capture_into_slot confirmed', f.r.ok && f.r.result.loaded && st.captures[2] === libCap.name, { r: f.r, slot3: st.captures[2] });

  const libCab = cabs.result.library.find((c) => c.source === 'factory' && c.name !== st.irs[1]) || factoryCab;
  f = await confirmFlow('load_cab_into_slot', { source: 'factory', name: libCab.name, slot: 2 }, 'cancel');
  check('load_cab_into_slot cancelled', f.dialog && /cab\/IR slot 2\?$/.test(f.dialog.title) && !f.r.ok && f.r.error === errors.cancelled, f);
  f = await confirmFlow('load_cab_into_slot', { source: 'factory', name: libCab.name, slot: 2 }, 'confirm');
  st = await state();
  check('load_cab_into_slot confirmed', f.r.ok && st.irs[1] === libCab.name, { r: f.r, slot2: st.irs[1] });

  let pre = await call('get_current_preset');
  const mics = (pre.result && pre.result.cab.mics) || [];
  const newMic = mics.find((m) => m !== pre.result.cab.mic) || pre.result.cab.mic;
  f = await confirmFlow('set_cab_mic', { mic: newMic, position: 2 }, 'cancel');
  check('set_cab_mic: the dialog (old → new); cancelled', f.dialog && /^Change the mic of cab slot \d+\?$/.test(f.dialog.title) && f.dialog.lines[0].includes('→ ' + newMic + ', position 2') && !f.r.ok, f);
  f = await confirmFlow('set_cab_mic', { mic: newMic, position: 2 }, 'confirm');
  await sleep(500); u = await ui();
  check('set_cab_mic confirmed', f.r.ok && f.r.result.mic === newMic && f.r.result.position === 2 && u.cab.mic === newMic, { r: f.r, cab: u.cab });

  f = await confirmFlow('assign_footswitch', { footswitch: 'IIB', preset: 5 }, 'cancel');
  check('assign_footswitch: the dialog; cancelled', f.dialog && f.dialog.title.startsWith('Assign preset 5 “') && f.dialog.title.endsWith('” to footswitch IIB?') && !f.r.ok, f);
  // Confirmed with unsaved edits: the editor's own "Save changes?" prompt comes next (the path of the user's click).
  await call('set_amp', { gain: 5 });
  const assign = call('assign_footswitch', { footswitch: 'IIB', preset: 5 }, 600000);
  const ad = await waitDialog();
  check('assign_footswitch with unsaved edits: the dialog says the editor asks next', ad && ad.lines.some((l) => /unsaved edits; the editor asks about them next/.test(l)), ad);
  await remote('/agent?dialog=confirm');
  let pend = ''; for (let i = 0; i < 40 && !pend; i++) { pend = (await ui()).pendingAssignment; if (!pend) await sleep(100); }
  check('…then the editor\'s own unsaved-edits prompt opens', pend === 'IIB 4', pend);
  await remote('/switch?choice=save');
  f = { r: await assign };
  st = await state();
  check('assign_footswitch confirmed', f.r.ok && f.r.result.assigned && st.footswitch.iib === 4, { r: f.r, fs: st.footswitch });

  f = await confirmFlow('cloud_send', { product_id: pid }, 'cancel');
  check('cloud_send: the editor\'s Send sheet; cancelled', f.dialog && f.dialog.kind === 'send' && f.dialog.name === 'Glass Pane Clean' && !f.r.ok && f.r.error === errors.cancelled, f);
  f = await confirmFlow('cloud_send', { product_id: pid }, 'confirm');
  await sleep(500);
  const lib = await remote('/library');
  check('cloud_send confirmed → in the pedal\'s library', f.r.ok && f.r.result.sent && lib.user.some((x) => x.includes('Glass Pane Clean')), { r: f.r, user: lib.user });
  // Review #1: the call answers after the transfer, and no "load it into a slot?" offer is left open, so the
  // assistant can go straight on.
  r = await call('set_amp', { gain: 4 });
  check('cloud_send: the next call is not busy (no slot offer left open)', r.ok, r);

  // ---- review #5: a dialog an assistant's call waits on closes when AI assistants are turned off
  let pendingSave = call('save', {}, 600000);
  let d = await waitDialog();
  await remote('/agent?enabled=0');
  let gone = await remote('/agent?status=1');
  r = await pendingSave;
  check('AI assistants off with a confirmation open: the dialog closes, the call ends', d && !gone.dialog && gone.status === 'off' && !r.ok, { d, gone, r });
  await remote('/agent?enabled=1');
  await sleep(300);
  s = await call('get_status');
  check('…turned on again: the helper reconnects on the next call', s.ok && s.result.connected === true, s);
  await call('set_amp', { gain: 3.5 });   // edits the pedal hasn't saved, so save opens its dialog
  pendingSave = call('save', {}, 600000);
  d = await waitDialog();

  // ---- not connected (the save dialog above is still open: the pedal going away ends it)
  await remote('/disconnect');
  r = await pendingSave;
  check('disconnect with a confirmation open: the call ends with errors.notConnected, no dialog left', d && !r.ok && r.error === errors.notConnected && !(await remote('/agent?status=1')).dialog, { d, r });
  s = await call('get_status');
  check('not connected: get_status still answers', s.ok && s.result.connected === false && s.result.pedal === null, s);
  r = await call('get_current_preset');
  check('not connected: errors.notConnected', !r.ok && r.error === errors.notConnected, r);
  r = await call('set_amp', { gain: 5 });
  check('not connected: live tools too', !r.ok && r.error === errors.notConnected, r);
  r = await call('cloud_preview', { product_id: pid });
  check('not connected: cloud_preview needs the pedal', !r.ok && r.error === errors.notConnected, r);
  r = await call('cloud_search', { query: 'clean' });
  // Without the demo pedal it is the real Cortex Cloud search (signed out here): it answers, but never with notConnected.
  check('not connected: cloud_search does not need the pedal', r.ok || (r.error && r.error !== errors.notConnected), r);
  await remote('/demo');

  // ---- the Activity log
  const log = await remote('/log?since=0');
  const lines = (log.lines || []).filter((l) => l.includes('Assistant: '));
  check('Activity: "Assistant: …" lines (connect, reads, edits, refusals)', lines.some((l) => /Assistant: Claude Code connected/.test(l)) && lines.some((l) => /Assistant: read the current preset/.test(l))
    && lines.some((l) => /Assistant: amp Gain 6\.0/.test(l)) && lines.some((l) => /Assistant: refused set_amp: Raise Level in smaller steps/.test(l)), lines.slice(-8));

  child.stdin.end();
  await sleep(300);
  const after = await remote('/agent?status=1');
  check('helper gone → the connection closes, status back to messages.statusWaiting', after.clients.length === 0 && after.statusText === messages.statusWaiting, after);
  if (stderr.trim()) console.log('  (helper stderr)\n' + stderr.trim().split('\n').map((l) => '    ' + l).join('\n'));
  console.log((failed ? 'FAILED ' : 'passed ') + passed + '/' + (passed + failed) + (failed ? '  (' + failures.join('; ') + ')' : ''));
  process.exit(failed ? 1 : 0);
})().catch((err) => { console.error(err); child.kill(); process.exit(2); });
