'use strict';
// A prebuilt addon pairs this package's sources and version with a bundle's
// library, so the two must be one AgentCore release: the same version (a
// development build of it, or the release itself), the ABI revision the sources
// speak, and a library that is the file its manifest pins.

const { createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const FINAL = /^\d+\.\d+\.\d+$/;
const BUILT_DEV = /^(\d+\.\d+\.\d+)-dev\+[0-9a-f]{12}(\.dirty)?$/;

function packageVersionOf(built) {
  if (FINAL.test(built)) return built;
  const match = BUILT_DEV.exec(built);
  if (!match) throw new Error(`bundle version ${built} is neither a final X.Y.Z nor X.Y.Z-dev+<commit12>`);
  return `${match[1]}-dev.0`;
}

function verifyBundle(bundle, { release = false, packageRoot = path.resolve(__dirname, '..') } = {}) {
  const manifest = JSON.parse(fs.readFileSync(path.join(bundle, 'manifest.json'), 'utf8'));
  const declared = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8')).version;
  const expected = packageVersionOf(manifest.version);
  if (release && !FINAL.test(manifest.version)) {
    throw new Error(`development version ${manifest.version} cannot go into a formal release package`);
  }
  if (declared !== expected) {
    throw new Error(`the bundle is AgentCore ${manifest.version} (package version ${expected}), but package.json says ${declared}`);
  }
  const speaks = /^const ABI_REVISION = (\d+);$/m.exec(fs.readFileSync(path.join(packageRoot, 'index.js'), 'utf8'));
  if (!speaks) throw new Error('index.js no longer declares ABI_REVISION');
  if (Number(speaks[1]) !== manifest.contract.binary_abi_revision) {
    throw new Error(`the bundle implements ABI revision ${manifest.contract.binary_abi_revision}, but index.js speaks ${speaks[1]}`);
  }
  const pinned = manifest.files.find((file) => file.path === manifest.shared_library.path);
  if (!pinned) throw new Error(`the manifest does not pin ${manifest.shared_library.path}`);
  const digest = createHash('sha256').update(fs.readFileSync(path.join(bundle, manifest.shared_library.path))).digest('hex');
  if (digest !== pinned.sha256) throw new Error(`${manifest.shared_library.path} is not the file its manifest pins`);
  return manifest;
}

module.exports = { verifyBundle, packageVersionOf };
