#!/usr/bin/env node
'use strict';

// Conformance test for a Nano Cortex MCP helper (mcp/PROTOCOL.md). Both editions run it against their own helper:
//   node mcp/conformance.js                                  # this edition's helper (node mcp/helper.js)
//   node mcp/conformance.js -- <helper command> [args…]       # any other (the native edition passes its binary)
// It plays the editor: a fake socket server in a private temporary folder (NANO_MCP_DIR), and checks the MCP side
// (initialize, tools, prompts, calls, errors) and the socket side (hello, token, calls, reconnects) of the helper.
// Exit code 0 when every check passes. Needs only Node; macOS and Linux (named pipes on Windows are not covered).

const fs = require('fs');
const os = require('os');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');
const { writeToken, lineReader } = require('./endpoint');

const CONTRACT = JSON.parse(fs.readFileSync(path.join(__dirname, 'tools.json'), 'utf8'));
const argv = process.argv.slice(2);
const dash = argv.indexOf('--');
const command = dash >= 0 ? argv.slice(dash + 1) : [process.execPath, path.join(__dirname, 'helper.js')];

let passed = 0, failed = 0;
function check(name, ok, detail) {
  if (ok) { passed++; console.log('  ok   ' + name); } else { failed++; console.log('  FAIL ' + name + (detail !== undefined ? '\n       ' + JSON.stringify(detail).slice(0, 600) : '')); }
}

// ------------------------------------------------------------------ the helper process

function startHelper(dir) {
  const child = spawn(command[0], command.slice(1), { env: { ...process.env, NANO_MCP_DIR: dir, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['pipe', 'pipe', 'pipe'] });
  const waiting = new Map();
  let nextId = 1;
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d; });
  child.stdout.on('data', lineReader((msg) => {
    if (msg.id !== undefined && waiting.has(msg.id)) { const w = waiting.get(msg.id); waiting.delete(msg.id); w(msg); }
  }, () => { stderr += '[conformance: helper wrote a line that is not JSON]\n'; }));
  const request = (method, params, ms = 8000) => new Promise((resolve) => {
    const id = nextId++;
    const t = setTimeout(() => { waiting.delete(id); resolve({ timeout: true }); }, ms);
    waiting.set(id, (m) => { clearTimeout(t); resolve(m); });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  const notify = (method, params) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
  const raw = (line) => child.stdin.write(line + '\n');
  return { child, request, notify, raw, stderr: () => stderr };
}

// ------------------------------------------------------------------ the fake editor

function startEditor(dir, token, behave) {
  const sock = path.join(dir, 'editor.sock');
  try { fs.unlinkSync(sock); } catch { /* none */ }
  const ed = { hellos: [], calls: [], conns: new Set() };
  ed.server = net.createServer((c) => {
    ed.conns.add(c);
    c.on('close', () => ed.conns.delete(c));
    let greeted = false;
    c.on('data', lineReader((msg) => {
      if (!greeted) {
        ed.hellos.push(msg);
        if (msg.type !== 'hello' || msg.token !== token) { c.end(JSON.stringify({ type: 'hello', ok: false, error: 'bad token' }) + '\n'); return; }
        greeted = true;
        c.write(JSON.stringify({ type: 'hello', ok: true, editor: { name: 'Fake editor', edition: 'test', version: '0', contract: CONTRACT.contractVersion } }) + '\n');
        return;
      }
      ed.calls.push(msg);
      behave(msg, c);
    }, () => c.destroy()));
  });
  return new Promise((resolve) => ed.server.listen(sock, () => resolve(ed)));
}
const answer = (c, msg, body) => c.write(JSON.stringify({ type: 'result', id: msg.id, ...body }) + '\n');
const closeEditor = (ed) => new Promise((resolve) => { for (const c of ed.conns) c.destroy(); ed.server.close(() => resolve()); });
const textOf = (r) => r && r.result && r.result.content && r.result.content[0] && r.result.content[0].text;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function hasRef(node) {
  if (Array.isArray(node)) return node.some(hasRef);
  if (!node || typeof node !== 'object') return false;
  return Object.prototype.hasOwnProperty.call(node, '$ref') || Object.values(node).some(hasRef);
}

// ------------------------------------------------------------------ the checks

(async () => {
  console.log('MCP helper conformance: ' + command.join(' '));
  const dir = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'ncmcp-'));
  fs.chmodSync(dir, 0o700);
  const h = startHelper(dir);

  // MCP: initialize, version negotiation, instructions
  let r = await h.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'conformance', version: '1' } });
  check('initialize answers', r.result && r.result.serverInfo, r);
  check('initialize keeps a supported protocol version', r.result && r.result.protocolVersion === '2025-06-18', r.result);
  check('server name is nano-cortex', r.result && r.result.serverInfo.name === CONTRACT.server.name, r.result && r.result.serverInfo);
  check('server version is set', r.result && /^\d+\.\d+\.\d+/.test(String(r.result.serverInfo.version)), r.result && r.result.serverInfo);
  check('instructions are the contract\'s', r.result && r.result.instructions === CONTRACT.server.instructions);
  check('capabilities: tools and prompts', r.result && r.result.capabilities && r.result.capabilities.tools && r.result.capabilities.prompts, r.result && r.result.capabilities);
  h.notify('notifications/initialized', {});
  r = await h.request('initialize', { protocolVersion: '2099-01-01', capabilities: {}, clientInfo: { name: 'conformance', version: '1' } });
  check('an unknown protocol version gets the newest supported one', r.result && r.result.protocolVersion === '2025-11-25', r.result && r.result.protocolVersion);
  r = await h.request('ping', {});
  check('ping', r.result && Object.keys(r.result).length === 0, r);

  // tools/list
  r = await h.request('tools/list', {});
  const listed = (r.result && r.result.tools) || [];
  check('tools/list names = contract, in order', JSON.stringify(listed.map((t) => t.name)) === JSON.stringify(CONTRACT.tools.map((t) => t.name)), listed.map((t) => t.name));
  check('every inputSchema is an object schema', listed.length > 0 && listed.every((t) => t.inputSchema && t.inputSchema.type === 'object'), listed.filter((t) => !t.inputSchema || t.inputSchema.type !== 'object').map((t) => t.name));
  check('no $ref left in any schema', listed.length > 0 && !listed.some((t) => hasRef(t.inputSchema)));
  check('descriptions and titles = contract', listed.length > 0 && listed.every((t, i) => t.description === CONTRACT.tools[i].description && t.title === CONTRACT.tools[i].title));
  const ann = Object.fromEntries(listed.map((t) => [t.name, t.annotations || {}]));
  check('read tools are read-only', CONTRACT.tools.filter((t) => t.kind === 'read').every((t) => ann[t.name].readOnlyHint === true && ann[t.name].destructiveHint === false), ann.get_status);
  check('confirm tools are marked destructive', CONTRACT.tools.filter((t) => t.kind === 'confirm').every((t) => ann[t.name].destructiveHint === true && ann[t.name].readOnlyHint === false), ann.save);
  check('live tools are not read-only; discard_edits is destructive', ann.set_amp && ann.set_amp.readOnlyHint === false && ann.set_amp.destructiveHint === false && ann.discard_edits.destructiveHint === true, [ann.set_amp, ann.discard_edits]);
  check('cloud tools are open-world', ['cloud_search', 'cloud_open', 'cloud_preview', 'cloud_send'].every((n) => ann[n] && ann[n].openWorldHint === true));
  const amp = listed.find((t) => t.name === 'set_amp');
  check('set_amp schema inlined from $defs', amp && amp.inputSchema.properties && amp.inputSchema.properties.gain && amp.inputSchema.properties.gain.maximum === 10, amp && amp.inputSchema);

  // prompts
  r = await h.request('prompts/list', {});
  check('prompts/list has build_tone', r.result && r.result.prompts && r.result.prompts.some((p) => p.name === 'build_tone' && p.arguments && p.arguments[0].name === 'request'), r.result);
  r = await h.request('prompts/get', { name: 'build_tone', arguments: { request: 'a glassy clean in the style of a math-rock player' } });
  const ptext = r.result && r.result.messages && r.result.messages[0] && r.result.messages[0].content.text;
  check('prompts/get fills the request in', typeof ptext === 'string' && ptext.includes('a glassy clean in the style of a math-rock player') && !ptext.includes('{request}'), r);
  r = await h.request('prompts/get', { name: 'build_tone', arguments: {} });
  check('prompts/get without the required argument is an error', r.error && r.error.code === -32602, r);

  // errors
  r = await h.request('tools/call', { name: 'no_such_tool', arguments: {} });
  check('an unknown tool is a JSON-RPC error -32602', r.error && r.error.code === -32602, r);
  r = await h.request('resources/list', {});
  check('an unknown method is -32601', r.error && r.error.code === -32601, r);

  // calls without an editor
  r = await h.request('tools/call', { name: 'get_status', arguments: {} });
  check('no editor: isError with errors.editorNotRunning', r.result && r.result.isError === true && textOf(r) === CONTRACT.errors.editorNotRunning, r);

  // a token file but no socket
  const tokenFile = path.join(dir, 'token');
  let token = writeToken(tokenFile);
  r = await h.request('tools/call', { name: 'get_status', arguments: {} });
  check('token but no socket: errors.editorNotRunning', r.result && r.result.isError === true && textOf(r) === CONTRACT.errors.editorNotRunning, r);

  // a working editor
  let ed = await startEditor(dir, token, (msg, c) => {
    if (msg.tool === 'fail_me' || (msg.args && msg.args.gain === 9.9)) return answer(c, msg, { ok: false, error: 'Raise level in smaller steps.' });
    if (msg.tool === 'apply_tone') return;   // never answered: the editor quits mid-call below
    if (msg.tool === 'list_presets') return setTimeout(() => answer(c, msg, { ok: true, result: { presets: [{ number: 1, name: 'Clean' }] } }), 150);
    answer(c, msg, { ok: true, result: { echo: msg.tool, args: msg.args, summary: 'done' } });
  });
  r = await h.request('tools/call', { name: 'set_amp', arguments: { gain: 5.5 } });
  check('the helper says hello with the token from the file', ed.hellos.length === 1 && ed.hellos[0].type === 'hello' && ed.hellos[0].token === token, ed.hellos);
  check('hello carries the contract version and the client name', ed.hellos[0] && ed.hellos[0].contract === CONTRACT.contractVersion && ed.hellos[0].client && ed.hellos[0].client.name === 'conformance', ed.hellos[0]);
  check('the call reaches the editor with tool and args', ed.calls.length === 1 && ed.calls[0].type === 'call' && ed.calls[0].tool === 'set_amp' && ed.calls[0].args.gain === 5.5 && ed.calls[0].id !== undefined, ed.calls);
  check('a result comes back as structuredContent', r.result && !r.result.isError && r.result.structuredContent && r.result.structuredContent.echo === 'set_amp', r);
  let parsed = null; try { parsed = JSON.parse(textOf(r)); } catch { /* checked below */ }
  check('…and as JSON text', parsed && parsed.summary === 'done', textOf(r));
  r = await h.request('tools/call', { name: 'set_amp', arguments: { gain: 9.9 } });
  check('an editor refusal is isError with its text', r.result && r.result.isError === true && textOf(r) === 'Raise level in smaller steps.', r);
  r = await h.request('tools/call', { name: 'get_status' });
  check('missing arguments are sent as {}', ed.calls.at(-1) && ed.calls.at(-1).tool === 'get_status' && JSON.stringify(ed.calls.at(-1).args) === '{}', ed.calls.at(-1));
  const [a, b] = await Promise.all([h.request('tools/call', { name: 'list_presets', arguments: {} }), h.request('tools/call', { name: 'get_status', arguments: {} })]);
  check('concurrent calls are matched by id', a.result && a.result.structuredContent && a.result.structuredContent.presets && b.result && b.result.structuredContent.echo === 'get_status', [a, b]);
  check('one connection for all calls', ed.hellos.length === 1, ed.hellos.length);

  // the editor goes away mid-call, then comes back with a new token
  const before = ed.calls.length;
  const pending = h.request('tools/call', { name: 'apply_tone', arguments: {} }, 5000);
  await sleep(100);
  await closeEditor(ed);
  r = await pending;
  check('a call cut off by the editor closing is isError', ed.calls.length === before + 1 && r.result && r.result.isError === true, r);
  r = await h.request('tools/call', { name: 'get_status', arguments: {} });
  check('after the editor quit: errors.editorNotRunning', r.result && r.result.isError === true && textOf(r) === CONTRACT.errors.editorNotRunning, r);
  token = writeToken(tokenFile);
  ed = await startEditor(dir, token, (msg, c) => answer(c, msg, { ok: true, result: { again: true } }));
  r = await h.request('tools/call', { name: 'get_status', arguments: {} });
  check('the editor restarted: the helper reconnects with the new token', r.result && !r.result.isError && r.result.structuredContent.again === true && ed.hellos[0] && ed.hellos[0].token === token, r);

  // a wrong token: the editor refuses the hello
  await closeEditor(ed);
  ed = await startEditor(dir, 'f'.repeat(64), () => {});
  r = await h.request('tools/call', { name: 'get_status', arguments: {} });
  check('a refused hello is isError with the editor\'s reason', r.result && r.result.isError === true && /bad token/.test(textOf(r)), r);
  await closeEditor(ed);

  // a folder others can read is refused
  if (process.platform !== 'win32') {
    fs.chmodSync(dir, 0o755);
    ed = await startEditor(dir, token, (msg, c) => answer(c, msg, { ok: true, result: {} }));
    r = await h.request('tools/call', { name: 'get_status', arguments: {} });
    check('a folder that is not private is refused (no connection made)', r.result && r.result.isError === true && /not private/.test(textOf(r)) && ed.hellos.length === 0, r);
    await closeEditor(ed);
    fs.chmodSync(dir, 0o700);
  }

  // stdio hygiene: a bad line, then the helper exits when stdin closes
  h.raw('this is not json');
  r = await h.request('ping', {});
  check('a line that is not JSON does not stop the helper', r.result !== undefined, r);
  const exited = new Promise((resolve) => h.child.on('exit', (code) => resolve(code)));
  h.child.stdin.end();
  const code = await Promise.race([exited, sleep(3000).then(() => 'still running')]);
  check('the helper exits when stdin closes', code === 0, code);
  if (h.stderr().trim()) console.log('  (helper stderr)\n' + h.stderr().trim().split('\n').map((l) => '    ' + l).join('\n'));

  fs.rmSync(dir, { recursive: true, force: true });
  console.log((failed ? 'FAILED ' : 'passed ') + passed + '/' + (passed + failed));
  process.exit(failed ? 1 : 0);
})().catch((err) => { console.error(err); process.exit(2); });
