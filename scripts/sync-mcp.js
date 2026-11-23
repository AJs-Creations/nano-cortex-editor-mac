#!/usr/bin/env node
'use strict';

// The shared MCP contract (AI assistants, DECISIONS #44): the Electron edition's mcp/ folder is the source of truth;
// this repo keeps a verbatim copy of it in mcp/ (tools.json, PROTOCOL.md, helper.js, endpoint.js, conformance.js, build-mcpb.js).
// Change it there first, then copy it here, then implement the change in both editors (mcp/PROTOCOL.md).
//   node scripts/sync-mcp.js                 copy from ../nano-cortex-editor/mcp
//   node scripts/sync-mcp.js <path>          copy from another checkout (its root or its mcp/ folder)
//   node scripts/sync-mcp.js --check [path]  exit 1 (and list the files) when mcp/ differs from the source

const fs = require('fs');
const path = require('path');

const FILES = ['tools.json', 'PROTOCOL.md', 'helper.js', 'endpoint.js', 'conformance.js', 'build-mcpb.js'];
const repo = path.resolve(__dirname, '..');
const target = path.join(repo, 'mcp');

const args = process.argv.slice(2);
const check = args.includes('--check');
const given = args.find((a) => a !== '--check');
let source = path.resolve(given || path.join(repo, '..', 'nano-cortex-editor'));
if (fs.existsSync(path.join(source, 'mcp', 'tools.json'))) source = path.join(source, 'mcp');
if (!fs.existsSync(path.join(source, 'tools.json'))) {
  console.error(`sync-mcp: no tools.json in ${source} (pass the Electron checkout or its mcp/ folder)`);
  process.exit(2);
}

const differs = FILES.filter((f) => {
  const a = fs.readFileSync(path.join(source, f));
  const b = fs.existsSync(path.join(target, f)) ? fs.readFileSync(path.join(target, f)) : null;
  return !b || !a.equals(b);
});

if (check) {
  if (differs.length) {
    console.error(`sync-mcp: mcp/ differs from ${source}: ${differs.join(', ')}. Run node scripts/sync-mcp.js${given ? ' ' + given : ''}.`);
    process.exit(1);
  }
  console.log(`sync-mcp: mcp/ matches ${source} (${FILES.length} files)`);
  process.exit(0);
}

fs.mkdirSync(target, { recursive: true });
for (const f of FILES) fs.copyFileSync(path.join(source, f), path.join(target, f));
console.log(differs.length ? `sync-mcp: copied ${FILES.length} files from ${source}; changed: ${differs.join(', ')}` : `sync-mcp: mcp/ was already up to date with ${source}`);
