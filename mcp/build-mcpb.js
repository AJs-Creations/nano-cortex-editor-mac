#!/usr/bin/env node
'use strict';

// Builds the Claude Desktop bundle (.mcpb, a zip with manifest.json) from this folder:
//   node mcp/build-mcpb.js <version> <out dir> [icon.png]
// The bundle runs mcp/helper.js on Claude Desktop's own Node and reaches whichever Nano Cortex Editor is running
// (both editions listen on the same socket, mcp/PROTOCOL.md §1), so both release workflows attach the same file.
// Only Node's own modules: the zip is written here (deflate, fixed timestamps, so the same inputs give the same bytes).

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const [version, outDir, icon] = process.argv.slice(2);
if (!/^\d+\.\d+\.\d+/.test(version || '') || !outDir) {
  console.error('usage: node mcp/build-mcpb.js <version> <out dir> [icon.png]');
  process.exit(2);
}
const contract = JSON.parse(fs.readFileSync(path.join(__dirname, 'tools.json'), 'utf8'));

const manifest = {
  manifest_version: '0.3',
  name: 'nano-cortex',
  display_name: 'Nano Cortex Editor',
  version,
  description: 'Build tones on a Neural DSP Nano Cortex by talking to Claude, through the Nano Cortex Editor running on this computer. Unofficial.',
  long_description: 'Lets Claude read the pedal (presets, captures, cabs, effects) and make live edits through Nano Cortex Editor, which must be open with Settings → AI assistants turned on. Saving and anything stored on the pedal still needs your click in the editor. Works with both editions of the editor (the native macOS one and the cross-platform one). Unofficial: not affiliated with or endorsed by Neural DSP.',
  author: { name: 'AJs Creations', url: 'https://github.com/AJs-Creations' },
  homepage: 'https://github.com/AJs-Creations/nano-cortex-editor',
  support: 'https://github.com/AJs-Creations/nano-cortex-editor/issues',
  license: 'MIT',
  server: {
    type: 'node',
    entry_point: 'server/helper.js',
    mcp_config: { command: 'node', args: ['${__dirname}/server/helper.js'], env: {} },
  },
  tools: contract.tools.map((t) => ({ name: t.name, description: t.description })),
  tools_generated: false,
  prompts: contract.prompts.map((p) => ({
    name: p.name, description: p.description, arguments: p.arguments.map((a) => a.name),
    text: p.template.replace(/\{(\w+)\}/g, (_m, k) => '$' + '{arguments.' + k + '}'),
  })),
  keywords: ['guitar', 'nano cortex', 'tone', 'pedal'],
  compatibility: { platforms: ['darwin', 'win32'], runtimes: { node: '>=18.0.0' } },
};
if (icon) manifest.icon = 'icon.png';

const files = [
  ['manifest.json', Buffer.from(JSON.stringify(manifest, null, 2) + '\n')],
  ['package.json', Buffer.from(JSON.stringify({ name: 'nano-cortex-mcp', version, private: true, license: 'MIT' }, null, 2) + '\n')],
  ['server/helper.js', fs.readFileSync(path.join(__dirname, 'helper.js'))],
  ['server/endpoint.js', fs.readFileSync(path.join(__dirname, 'endpoint.js'))],
  ['server/tools.json', fs.readFileSync(path.join(__dirname, 'tools.json'))],
];
if (icon) files.push(['icon.png', fs.readFileSync(icon)]);

// ------------------------------------------------------------------ a minimal zip writer
const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc32 = (buf) => { let c = -1; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const DOS_TIME = 0, DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1;
const locals = [], centrals = [];
let offset = 0;
for (const [name, data] of files) {
  const nameBuf = Buffer.from(name), packed = zlib.deflateRawSync(data, { level: 9 }), crc = crc32(data);
  const head = Buffer.alloc(30);
  head.writeUInt32LE(0x04034b50, 0); head.writeUInt16LE(20, 4); head.writeUInt16LE(0x0800, 6); head.writeUInt16LE(8, 8);
  head.writeUInt16LE(DOS_TIME, 10); head.writeUInt16LE(DOS_DATE, 12); head.writeUInt32LE(crc, 14);
  head.writeUInt32LE(packed.length, 18); head.writeUInt32LE(data.length, 22); head.writeUInt16LE(nameBuf.length, 26);
  locals.push(head, nameBuf, packed);
  const cen = Buffer.alloc(46);
  cen.writeUInt32LE(0x02014b50, 0); cen.writeUInt16LE(0x031e, 4); cen.writeUInt16LE(20, 6); cen.writeUInt16LE(0x0800, 8); cen.writeUInt16LE(8, 10);
  cen.writeUInt16LE(DOS_TIME, 12); cen.writeUInt16LE(DOS_DATE, 14); cen.writeUInt32LE(crc, 16);
  cen.writeUInt32LE(packed.length, 20); cen.writeUInt32LE(data.length, 24); cen.writeUInt16LE(nameBuf.length, 28);
  cen.writeUInt32LE((0o100644 << 16) >>> 0, 38); cen.writeUInt32LE(offset, 42);
  centrals.push(cen, nameBuf);
  offset += head.length + nameBuf.length + packed.length;
}
const cenSize = centrals.reduce((n, b) => n + b.length, 0);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
end.writeUInt32LE(cenSize, 12); end.writeUInt32LE(offset, 16);

fs.mkdirSync(outDir, { recursive: true });
const out = path.join(outDir, 'nano-cortex-' + version + '.mcpb');
fs.writeFileSync(out, Buffer.concat([...locals, ...centrals, end]));
console.log(out);
