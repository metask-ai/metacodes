#!/usr/bin/env node
'use strict';
// Build the native addon for this platform and stage it with an AgentCore bundle:
//
//   zig build agentcore:bundle -Dtarget=<target> -Doptimize=ReleaseSafe
//   node sdk/node/scripts/build.js --bundle zig-out/agentcore/<resolved-target>
//
// Output: sdk/node/prebuilds/<platform>-<arch>/{metacodes.node, metacodes-LICENSE,
// libmetask_agentcore.*, rg, ripgrep-LICENSE-MIT}.
// The addon is compiled with `zig cc` against this Node's own Node-API headers
// (<node prefix>/include/node, or NODE_INCLUDE_DIR) and the repository's
// sdk/metask/agentcore.h. Without --bundle only the addon is built. A bundle must
// be the AgentCore release this package declares (scripts/verify_bundle.js), and
// --release refuses a development one, before anything is compiled.

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const here = path.resolve(__dirname, '..');
const repo = path.resolve(here, '..', '..');

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

if (process.platform === 'win32') {
  console.error('metacodes: the Node addon does not support Windows yet (it needs dlopen and pthreads).');
  process.exit(1);
}

const bundle = argument('--bundle');
if (bundle) {
  const { verifyBundle } = require('./verify_bundle.js');
  try {
    verifyBundle(bundle, { release: process.argv.includes('--release') });
  } catch (error) {
    console.error(`metacodes: cannot package ${bundle}: ${error.message}`);
    process.exit(1);
  }
}
const out = path.resolve(argument('--out') || path.join(here, 'prebuilds', `${process.platform}-${process.arch}`));
const zig = process.env.ZIG || 'zig';
const nodeInclude = process.env.NODE_INCLUDE_DIR || path.join(path.dirname(process.execPath), '..', 'include', 'node');
if (!fs.existsSync(path.join(nodeInclude, 'node_api.h'))) {
  console.error(`metacodes: node_api.h not found in ${nodeInclude}; set NODE_INCLUDE_DIR`);
  process.exit(1);
}

fs.mkdirSync(out, { recursive: true });
const args = [
  'cc', '-shared', '-fPIC', '-O2', '-std=c11', '-pthread',
  '-Wall', '-Wextra', '-Wno-unused-parameter',
  '-I', nodeInclude,
  '-I', path.join(repo, 'sdk'),
  '-o', path.join(out, 'metacodes.node'),
  path.join(here, 'src', 'addon.c'),
];
if (process.platform === 'darwin') args.push('-Wl,-undefined,dynamic_lookup');
execFileSync(zig, args, { stdio: 'inherit' });

fs.copyFileSync(path.join(repo, 'LICENSE'), path.join(out, 'metacodes-LICENSE'));

if (bundle) {
  const manifest = JSON.parse(fs.readFileSync(path.join(bundle, 'manifest.json'), 'utf8'));
  const library = path.join(bundle, manifest.shared_library.path);
  fs.copyFileSync(library, path.join(out, path.basename(library)));
  const bin = path.join(bundle, 'bin');
  if (fs.existsSync(bin)) {
    for (const name of fs.readdirSync(bin)) {
      fs.copyFileSync(path.join(bin, name), path.join(out, name));
      if (name === 'rg') fs.chmodSync(path.join(out, name), 0o755);
    }
  }
}
console.log(out);
