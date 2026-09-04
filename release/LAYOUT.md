# CLI release layout

The `metacodes-cli` release unit is the default install prefix sealed with a
manifest (#47 §5.2, stage 5 / #80). `zig build release:stage -Drelease-layout=true
--prefix <dir>` produces the tree; `release:manifest` writes `manifest.json`;
`release:check` validates it statically; `release:verify` (native target only)
also runs the executables. Nothing outside this tree is part of the unit, and a
file inside it that the manifest does not name fails `release:check`.

```
metacodes-<version>-<target-id>/
├── bin/
│   ├── metacodes[.exe]                 role=primary_executable
│   └── rg[.exe]                        role=runtime_asset (ripgrep, Glob/Grep)
├── vendor/tinykg/
│   ├── tinykg[.exe]                    role=runtime_asset (memory / task control plane)
│   └── tinykg.provenance.json          staging receipt (scripts/stage_tinykg_binary.py)
├── share/licenses/
│   ├── metacodes-LICENSE               the repository LICENSE (MIT)
│   ├── ripgrep-LICENSE-MIT             vendor/ripgrep/LICENSE-MIT
│   ├── tinykg-LICENSE                  vendor/tinykg/LICENSE (Apache-2.0)
│   └── THIRD_PARTY_NOTICES.md          rendered by scripts/gen_third_party_notices.py
├── share/doc/
│   ├── README.md                       the repository README
│   └── CHANGELOG-<version>.md          the repository CHANGELOG at this version
└── manifest.json                       release/manifest.schema.json; not listed in its own files[]
```

| Path | Role | Where it comes from | Who checks it |
|---|---|---|---|
| `bin/metacodes[.exe]` | the product | `zig build` (ReleaseSafe for a release) | `--version --json` must be a strict subset of the manifest (`release:verify`) |
| `bin/rg[.exe]` | runtime asset | `scripts/stage_ripgrep_binary.py` from `vendor/ripgrep/manifest.json` | digest in `files[]` and `components[]`; `doctor --strict` resolves it here under the release layout |
| `vendor/tinykg/tinykg[.exe]` | runtime asset | `scripts/stage_tinykg_binary.py` from `vendor/tinykg/manifest.json` | digest; `doctor --strict`; `tinykg version` equals `components[tinykg].version` (`release:verify`) |
| `vendor/tinykg/tinykg.provenance.json` | staging receipt | same script | listed in `files[]`; `components[tinykg].provenance_path` |
| `share/licenses/*` | licence texts and notices | repository files, `THIRD_PARTY_NOTICES.md` generated | every `components[].license_path` exists and is non-empty; the notices name every runtime asset |
| `share/doc/*` | operator documentation | repository files | listed in `files[]` |
| `manifest.json` | the contract | `scripts/release_manifest.zig` | `release/manifest_contract.zig` (schema, identity, files, components, compatibility) |

The relative position of `bin/` and `vendor/tinykg/` is load-bearing: the
executable resolves TinyKG at `../vendor/tinykg/` from its own directory and, under
the release layout, ripgrep beside itself before `PATH` (#78, #79). Unpack the
archive anywhere; do not move files inside it.

## Release channels

`release.version` is the repository version (`build.zig.zon`, mirrored by
`src/version.zig`). A version without a pre-release part is the **stable**
channel: `release.tag` is the bare `X.Y.Z` git tag (the repository's tag
convention, #47 Q1), the working tree must be clean, and `git describe --tags
--exact-match HEAD` must equal the version — `release:manifest` refuses to
write otherwise. A version with a pre-release part (`0.2.0-dev`) is the **pre**
channel: `version` gains `+<commit12>` as build metadata, `tag` is null, and a
missing `share/licenses/metacodes-LICENSE` is a warning rather than an error.

## What is deliberately not in the unit

Debug executables, the test harness servers, evaluation shadows, the AgentCore
bundle (a separate unit with its own manifest), and anything a developer builds
into `zig-out/` that the manifest does not name.
