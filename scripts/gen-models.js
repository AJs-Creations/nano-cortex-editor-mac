#!/usr/bin/env node
// Regenerates NanoCore/Sources/NanoCore/Models.swift from the Electron edition's generated pro/core.js (the upstream
// DrD85 editor plus that repo's editor/patches). Run it after each upstream sync there:
//
//   node scripts/gen-models.js [path/to/pro/core.js]        (default: ../nano-cortex-editor/pro/core.js)
//
// core.js is evaluated in a vm sandbox with browser stubs (as that repo's scripts/build-core.js does), then the slot
// lists (None + preFxModels, postFx1Models, postFx2Models, postFx3Models) are read from it: every model's name,
// category, id and parameters (name, index, wire index, default value, range or options, value curve). It fails
// loudly if core.js no longer has what it reads. Review the diff of Models.swift like any other change.

'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const source = path.resolve(process.argv[2] || path.join(root, '..', 'nano-cortex-editor', 'pro', 'core.js'));
const target = path.join(root, 'NanoCore', 'Sources', 'NanoCore', 'Models.swift');
const code = fs.readFileSync(source, 'utf8');

const element = () => ({
  hidden: true, textContent: '', value: '', title: '', disabled: false, style: { setProperty() {} },
  classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
  addEventListener() {}, appendChild() {}, append() {}, setAttribute() {}, querySelector: () => null, querySelectorAll: () => [],
});
const sandbox = {
  console, setTimeout, clearTimeout, setInterval, clearInterval, TextEncoder, TextDecoder, DataView, Uint8Array, Float32Array,
  document: { getElementById: () => null, createElement: element, querySelector: () => null, querySelectorAll: () => [], body: element(), addEventListener() {} },
  navigator: { bluetooth: undefined, userAgent: 'sandbox', platform: 'sandbox' },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  location: { search: '' },
};
sandbox.window = sandbox;
// `const` bindings don't land on the sandbox object: read them with a probe at the end of the script.
const lists = vm.runInNewContext(code + '\n;({ pre: preFxModels, post1: postFx1Models, post2: postFx2Models, post3: postFx3Models });',
  sandbox, { filename: path.basename(source) });
for (const k of ['pre', 'post1', 'post2', 'post3']) {
  if (!Array.isArray(lists[k]) || !lists[k].length) throw new Error(`${source}: the ${k} model list is missing or empty`);
}

// ---------------------------------------------------------------- Swift literals
const num = (n) => {
  if (typeof n !== 'number' || !Number.isFinite(n)) throw new Error('not a finite number: ' + n);
  return String(n);
};
const str = (s) => JSON.stringify(String(s));
const hexByte = (b) => '0x' + b.toString(16).toUpperCase().padStart(2, '0');

function meta(m, where) {
  if (!m) throw new Error(where + ': no metadata');
  if (m.kind === 'enum') return '.options([' + m.options.map(str).join(', ') + '])';
  if (m.kind !== 'range') throw new Error(where + ': unknown metadata kind ' + m.kind);
  let curve = '';
  if (m.normalizedReversePower) curve = ', curve: .reversePower(' + num(m.normalizedReversePower) + ')';
  else if (m.normalizedPower && m.normalizedPower !== 1) curve = ', curve: .power(' + num(m.normalizedPower) + ')';
  const decimals = m.decimals === null || m.decimals === undefined ? 'nil' : num(m.decimals);
  return `.range(min: ${num(m.min)}, max: ${num(m.max)}, step: ${num(m.step)}, unit: ${str(m.unit || '')}, decimals: ${decimals}${curve})`;
}

function param(p, model) {
  const where = model.name + ' / ' + p.name;
  const wire = p.wireIndex === undefined || p.wireIndex === p.index ? '' : `, wireIndex: ${num(p.wireIndex)}`;
  return `ParamDef(name: ${str(p.name)}, index: ${num(p.index)}${wire}, defaultValue: ${num(p.value)}, meta: ${meta(p.meta, where)})`;
}

function model(m) {
  const id = m.id ? '[' + m.id.map(hexByte).join(', ') + ']' : 'nil';
  return `        ModelDef(name: ${str(m.name)}, category: ${str(m.category)}, id: ${id}, params: [${(m.params || []).map(p => param(p, m)).join(', ')}]),`;
}

const none = '        ModelDef(name: "None", category: "Bypass", id: nil, params: []),';
const block = (name, list) => [`    public static let ${name}: [ModelDef] = [`, none, ...list.map(model), '    ]'];

const out = [
  `// GENERATED from the Electron edition's pro/core.js (upstream DrD85 editor, MIT, plus that repo's editor/patches) by`,
  `// scripts/gen-models.js; regenerate, don't edit. Effect models per slot family, with their current-state ids (fields`,
  `// 48–52) and parameter metadata: UI order, wire index (the position in the 99 write and the 138 reply) and value curve.`,
  '',
  'import Foundation',
  '',
  '/// How a normalized wire value maps onto a range (Electron\'s `normalizedPower` / `normalizedReversePower`):',
  '/// linear `min + n·(max − min)`, power `min + nᵖ·(max − min)`, reverse power `min + (1 − (1 − n)ᵖ)·(max − min)`.',
  'public enum ParamCurve: Equatable, Sendable {',
  '    case linear',
  '    case power(Double)',
  '    case reversePower(Double)',
  '}',
  '',
  'public enum ParamMeta: Equatable, Sendable {',
  '    case range(min: Double, max: Double, step: Double, unit: String, decimals: Int?, curve: ParamCurve = .linear)',
  '    case options([String])',
  '}',
  '',
  '/// `index` is the parameter\'s place in the UI (and in `Block.values`); `wireIndex` is its place on the wire, which',
  '/// differs only where the pedal orders them differently (Graphic 9: HPF first, then the nine bands).',
  'public struct ParamDef: Equatable, Sendable {',
  '    public let name: String; public let index: Int; public let wireIndex: Int; public let defaultValue: Double; public let meta: ParamMeta?',
  '    public init(name: String, index: Int, wireIndex: Int? = nil, defaultValue: Double, meta: ParamMeta?) { self.name = name; self.index = index; self.wireIndex = wireIndex ?? index; self.defaultValue = defaultValue; self.meta = meta }',
  '}',
  '',
  'public struct ModelDef: Equatable, Sendable {',
  '    public let name: String; public let category: String; public let id: [UInt8]?; public let params: [ParamDef]',
  '    public init(name: String, category: String, id: [UInt8]?, params: [ParamDef]) { self.name = name; self.category = category; self.id = id; self.params = params }',
  '    public var idHex: String? { id.map { $0.map { String(format: "%02X", $0) }.joined() } }',
  '}',
  '',
  'public enum Models {',
  ...block('pre1', lists.pre),
  ...block('post1', lists.post1),
  ...block('post2', lists.post2),
  ...block('post3', lists.post3),
  '    /// Models available in a slot: pre1/pre2 share one list, post1, post2, post3 each have their own.',
  '    public static func list(for slot: String) -> [ModelDef] { switch slot { case "pre1", "pre2": return pre1; case "post1": return post1; case "post2": return post2; default: return post3 } }',
  '    public static func byId(_ idHex: String, in slot: String) -> ModelDef? { list(for: slot).first { $0.idHex == idHex.uppercased() } }',
  '}',
  '',
];

// Every model's wire indices must be a permutation of 0..<count, or writes and reads would miss parameters.
for (const m of [].concat(lists.pre, lists.post1, lists.post2, lists.post3)) {
  const wires = (m.params || []).map(p => p.wireIndex === undefined ? p.index : p.wireIndex).sort((a, b) => a - b);
  if (wires.some((w, i) => w !== i)) throw new Error(m.name + ': wire indices are not 0..' + (wires.length - 1) + ': ' + wires.join(','));
}

fs.writeFileSync(target, out.join('\n'));
console.log('Wrote ' + path.relative(root, target) + ' from ' + source);
