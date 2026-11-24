'use strict';

// Where the running editor listens for its MCP helper, and the checks both sides make before trusting it
// (mcp/PROTOCOL.md §1). No Electron in here: the helper (mcp/helper.js, run by the app's own Node) and the editor's
// socket server (src/mcp-server.js) both use it, and the conformance test points both at a temporary folder with
// NANO_MCP_DIR.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

function userTag() {
  try { return String(os.userInfo().username || 'user').replace(/[^A-Za-z0-9_.-]/g, '_'); } catch { return 'user'; }
}

// { dir, socket, token }. macOS and Linux: /tmp/nano-cortex-<uid>/editor.sock (short enough for the 104-byte limit
// on socket paths, and the same for every app that launches the helper, whatever its environment). Windows: a named
// pipe per user, the token in the per-user temp folder.
function endpoint(env = process.env) {
  const custom = env.NANO_MCP_DIR ? path.resolve(env.NANO_MCP_DIR) : '';
  if (process.platform === 'win32') {
    const dir = custom || path.join(os.tmpdir(), 'nano-cortex');
    const suffix = custom ? '-' + crypto.createHash('sha256').update(dir).digest('hex').slice(0, 8) : '';
    return { dir, socket: '\\\\.\\pipe\\nano-cortex-' + userTag() + suffix, token: path.join(dir, 'token') };
  }
  const dir = custom || path.join('/tmp', 'nano-cortex-' + os.userInfo().uid);
  return { dir, socket: path.join(dir, 'editor.sock'), token: path.join(dir, 'token') };
}

// null when `dir` is a private folder of this user (created with mode 0700 when `create`), else why not. A folder
// another user made first, a symlink, or one others can read is refused, by the editor and by the helper alike.
function checkPrivateDir(dir, { create = false } = {}) {
  if (process.platform === 'win32') {
    if (create) fs.mkdirSync(dir, { recursive: true });
    return fs.existsSync(dir) ? null : 'the folder ' + dir + ' does not exist';
  }
  let st;
  try { st = fs.lstatSync(dir); } catch (err) {
    if (err.code !== 'ENOENT') return 'cannot read ' + dir + ': ' + err.message;
    if (!create) return 'the folder ' + dir + ' does not exist';
    try { fs.mkdirSync(dir, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') return 'cannot create ' + dir + ': ' + e.message; }
    st = fs.lstatSync(dir);
  }
  if (st.isSymbolicLink()) return dir + ' is a symbolic link';
  if (!st.isDirectory()) return dir + ' is not a folder';
  if (st.uid !== process.getuid()) return dir + ' belongs to another user';
  if ((st.mode & 0o077) !== 0) return dir + ' is not private (mode ' + (st.mode & 0o777).toString(8) + ', expected 700)';
  return null;
}

// A new random token, written 0600 (replacing any old one atomically). The editor calls it each time it starts
// listening; the helper reads it fresh on every connect.
function writeToken(file) {
  const token = crypto.randomBytes(32).toString('hex');
  const tmp = file + '.' + process.pid + '.tmp';
  fs.writeFileSync(tmp, token + '\n', { mode: 0o600 });
  fs.renameSync(tmp, file);
  return token;
}

function readToken(file) {
  try {
    if (process.platform !== 'win32') {
      const st = fs.lstatSync(file);
      if (!st.isFile() || st.uid !== process.getuid() || (st.mode & 0o077) !== 0) return null;
    }
    const t = fs.readFileSync(file, 'utf8').trim();
    return /^[0-9a-f]{64}$/.test(t) ? t : null;
  } catch { return null; }
}

// Constant-time comparison of two tokens (strings).
function sameToken(a, b) {
  const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || ''));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
}

const MAX_LINE = 1024 * 1024;   // one message, either direction

// Splits a stream into JSON messages, one per line. onMessage(obj) for each; onError(text) for a line that is not
// JSON or is longer than MAX_LINE (whether or not its newline has arrived yet; the rest of such a line is skipped).
// When onError returns false nothing more is read from this stream: a socket's caller closes the connection then,
// while the helper's stdin answers a parse error and goes on.
function lineReader(onMessage, onError) {
  let buf = '';
  let skipping = false;   // inside a line that was already refused as too long
  let dead = false;
  const bad = (why) => { if (onError(why) === false) { dead = true; buf = ''; } };
  return (chunk) => {
    if (dead) return;
    buf += chunk.toString('utf8');
    let i;
    while (!dead && (i = buf.indexOf('\n')) >= 0) {
      const raw = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (skipping) { skipping = false; continue; }
      if (raw.length > MAX_LINE || Buffer.byteLength(raw, 'utf8') > MAX_LINE) { bad('message too long'); continue; }
      const line = raw.trim();
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { bad('not JSON'); continue; }
      onMessage(msg);
    }
    if (!dead && !skipping && buf.length > MAX_LINE) { buf = ''; skipping = true; bad('message too long'); }
    else if (skipping) buf = '';
  };
}

module.exports = { endpoint, checkPrivateDir, writeToken, readToken, sameToken, lineReader, MAX_LINE };
