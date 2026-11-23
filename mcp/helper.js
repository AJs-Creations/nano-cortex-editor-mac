#!/usr/bin/env node
'use strict';

// The Nano Cortex MCP helper (mcp/PROTOCOL.md). An assistant app launches it over stdio; it serves the shared tool
// list (mcp/tools.json) and forwards every call to the running editor over a private local socket. It never launches
// the editor (decision 3 of MCP-PLAN): when the editor is closed, or AI assistants are off, every call answers
// errors.editorNotRunning. Packaged builds run it with the app's own Node:
//   ELECTRON_RUN_AS_NODE=1 "<app executable>" "<resources>/app.asar.unpacked/mcp/helper.js"
// The native edition ships the same server in Swift; mcp/conformance.js holds both to the same behaviour.

const fs = require('fs');
const net = require('net');
const path = require('path');
const { endpoint, checkPrivateDir, readToken, lineReader } = require('./endpoint');

const CONTRACT = JSON.parse(fs.readFileSync(path.join(__dirname, 'tools.json'), 'utf8'));
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];   // newest first
const VERSION = (() => {
  for (const p of [path.join(__dirname, '..', 'package.json'), path.join(__dirname.replace('app.asar.unpacked', 'app.asar'), '..', 'package.json')]) {
    try { return JSON.parse(fs.readFileSync(p, 'utf8')).version; } catch { /* next */ }
  }
  return '0.0.0';
})();

// ------------------------------------------------------------------ the tool list as MCP serves it

// Every "$ref": "#/$defs/x" replaced by a copy of the definition (siblings such as a description kept), so each
// tool's schema stands alone.
function inline(node) {
  if (Array.isArray(node)) return node.map(inline);
  if (!node || typeof node !== 'object') return node;
  let out = {};
  if (typeof node.$ref === 'string') {
    const m = /^#\/\$defs\/(.+)$/.exec(node.$ref);
    if (!m || !CONTRACT.$defs[m[1]]) throw new Error('unknown $ref ' + node.$ref);
    out = inline(CONTRACT.$defs[m[1]]);
  }
  for (const [k, v] of Object.entries(node)) if (k !== '$ref') out[k] = inline(v);
  return out;
}

function annotations(t) {
  const read = t.kind === 'read' || t.name === 'cloud_search' || t.name === 'cloud_open';
  return {
    title: t.title,
    readOnlyHint: read,
    destructiveHint: !read && (t.kind === 'confirm' || Boolean(t.destructive)),
    idempotentHint: read,
    openWorldHint: t.kind === 'cloud' || t.name === 'cloud_send',
  };
}

const TOOLS = CONTRACT.tools.map((t) => ({
  name: t.name, title: t.title, description: t.description, inputSchema: inline(t.inputSchema), annotations: annotations(t),
}));
const KIND = new Map(CONTRACT.tools.map((t) => [t.name, t.kind]));

// How long a call may take before the helper gives up on the editor's answer. Confirmations wait for the user.
function timeoutFor(name, args) {
  if (KIND.get(name) === 'confirm') return 10 * 60 * 1000;
  if (name === 'get_slot_usage' && args && args.scan) return 5 * 60 * 1000;
  if (name === 'cloud_preview') return 3 * 60 * 1000;
  return 2 * 60 * 1000;
}

// ------------------------------------------------------------------ the editor link

let link = null;          // { socket, pending: Map<id, {resolve}>, ready: Promise<string|null> }
let nextCall = 1;
let clientInfo = { name: 'unknown', version: '' };

function connect() {
  const ep = endpoint();
  const bad = process.platform === 'win32' ? null : checkPrivateDir(ep.dir);
  if (bad) {
    // A missing folder just means the editor never listened: the usual "open the editor".
    return Promise.resolve(bad.endsWith('does not exist') ? CONTRACT.errors.editorNotRunning : 'Refusing to talk to the editor: ' + bad + '.');
  }
  const token = readToken(ep.token);
  if (!token) return Promise.resolve(CONTRACT.errors.editorNotRunning);
  return new Promise((resolve) => {
    const socket = net.createConnection(ep.socket);
    const me = { socket, pending: new Map(), hello: null };
    let settled = false;
    const done = (err) => { if (!settled) { settled = true; resolve(err); } };
    socket.on('connect', () => {
      socket.write(JSON.stringify({ type: 'hello', token, contract: CONTRACT.contractVersion, client: clientInfo }) + '\n');
    });
    socket.on('data', lineReader((msg) => {
      if (msg.type === 'hello') {
        if (msg.ok) { me.hello = msg.editor || {}; link = me; done(null); } else { done(String(msg.error || 'the editor refused the connection')); socket.destroy(); }
        return;
      }
      if (msg.type === 'result' && me.pending.has(msg.id)) {
        const p = me.pending.get(msg.id);
        me.pending.delete(msg.id);
        p.resolve(msg);
      }
    }, () => socket.destroy()));
    socket.on('error', () => done(CONTRACT.errors.editorNotRunning));
    socket.on('close', () => {
      done(CONTRACT.errors.editorNotRunning);
      if (link === me) link = null;
      for (const p of me.pending.values()) p.resolve({ ok: false, error: 'The editor closed the connection before answering. ' + CONTRACT.errors.editorNotRunning });
      me.pending.clear();
    });
  });
}

async function callEditor(name, args) {
  if (!link) {
    const err = await connect();
    if (err) return { ok: false, error: err };
  }
  const me = link;
  const id = nextCall++;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      me.pending.delete(id);
      resolve({ ok: false, error: 'The editor did not answer within ' + Math.round(timeoutFor(name, args) / 1000) + ' s.' });
    }, timeoutFor(name, args));
    me.pending.set(id, { resolve: (msg) => { clearTimeout(timer); resolve(msg); } });
    me.socket.write(JSON.stringify({ type: 'call', id, tool: name, args: args || {} }) + '\n');
  });
}

// ------------------------------------------------------------------ MCP over stdio (JSON-RPC 2.0, one message per line)

function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }
function reply(id, result) { send({ jsonrpc: '2.0', id, result }); }
function fail(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

function fillTemplate(text, args) {
  return text.replace(/\{(\w+)\}/g, (_m, k) => (args && args[k] !== undefined ? String(args[k]) : ''));
}

async function handle(msg) {
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') {
    if (msg && msg.id !== undefined && msg.method === undefined) return;   // a response to nothing we asked: ignore
    return fail(msg && msg.id !== undefined ? msg.id : null, -32600, 'Invalid request');
  }
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;
  if (!isRequest) return;   // notifications (initialized, cancelled, …) need no answer
  switch (method) {
    case 'initialize': {
      const asked = params && params.protocolVersion;
      if (params && params.clientInfo) clientInfo = { name: String(params.clientInfo.name || 'unknown').slice(0, 80), version: String(params.clientInfo.version || '').slice(0, 40) };
      return reply(id, {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false }, prompts: { listChanged: false } },
        serverInfo: { name: CONTRACT.server.name, title: CONTRACT.server.title, version: VERSION },
        instructions: CONTRACT.server.instructions,
      });
    }
    case 'ping': return reply(id, {});
    case 'tools/list': return reply(id, { tools: TOOLS });
    case 'prompts/list':
      return reply(id, { prompts: CONTRACT.prompts.map((p) => ({ name: p.name, title: p.title, description: p.description, arguments: p.arguments })) });
    case 'prompts/get': {
      const p = CONTRACT.prompts.find((x) => x.name === (params && params.name));
      if (!p) return fail(id, -32602, 'Unknown prompt: ' + (params && params.name));
      const args = (params && params.arguments) || {};
      for (const a of p.arguments) if (a.required && !String(args[a.name] || '').trim()) return fail(id, -32602, 'Missing argument: ' + a.name);
      return reply(id, { description: p.description, messages: [{ role: 'user', content: { type: 'text', text: fillTemplate(p.template, args) } }] });
    }
    case 'tools/call': {
      const name = params && params.name;
      if (!KIND.has(name)) return fail(id, -32602, 'Unknown tool: ' + name);
      const args = params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments) ? params.arguments : {};
      const r = await callEditor(name, args);
      if (!r.ok) return reply(id, { content: [{ type: 'text', text: String(r.error || 'The editor reported an error.') }], isError: true });
      const result = r.result === undefined ? {} : r.result;
      const out = { content: [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result, null, 2) }] };
      if (result && typeof result === 'object' && !Array.isArray(result)) out.structuredContent = result;
      return reply(id, out);
    }
    default: return fail(id, -32601, 'Method not found: ' + method);
  }
}

process.stdin.on('data', lineReader(
  (msg) => { Promise.resolve(handle(msg)).catch((err) => process.stderr.write('nano-cortex helper: ' + (err && err.stack || err) + '\n')); },
  () => fail(null, -32700, 'Parse error'),
));
process.stdin.on('end', () => process.exit(0));
