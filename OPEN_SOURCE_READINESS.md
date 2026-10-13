# Open-source readiness

The repository is currently public for review, but release readiness is **not yet complete**.

## Completed

- standalone Git history with `main` as the primary branch;
- independent build/package root and repository documentation;
- public API and embedding-surface inventory;
- TinyKG source removed and replaced by a cross-platform, SHA-256-pinned binary
  bundle plus an explicit override contract;
- local artifacts, evaluation runs, stores, and undeclared binaries ignored;
- contribution, governance, conduct, support, and security drafts;
- CI definitions scoped to the standalone repository;
- current-tree and targeted history credential review.
- repository-owned WorkBuddy release coverage that does not require an external
  checkout; ten installed-checkout tests remain an explicit external-only gate.

## Blocking owner decisions

- [x] Select and add the metacodes project license: the repository currently
      ships an MIT license. TinyKG's Apache-2.0 dependency declaration does not
      license metacodes.
- [ ] Confirm organization/repository ownership and public naming.
- [ ] Publish private security and conduct-reporting contacts.
- [ ] Decide whether the complete extracted history is public. It has been scrubbed
      for the known legacy hard-coded API token, but an independent secret scan is
      required immediately before visibility changes.
- [ ] Confirm trademarks, project name, and third-party notices with counsel or the
      responsible owner.

## Final launch gate

- [ ] Run an independent full-history scanner such as gitleaks.
- [ ] Review `THIRD_PARTY_NOTICES.md`, `vendor/tinykg/manifest.json`, and every
      distributed asset/license.
- [ ] Run native ReleaseSafe tests and AgentCore source-free consumer gates on the
      supported matrix.
- [ ] Verify public examples use placeholders and no paid endpoint by default.
- [x] Enable branch protection, required CI, private vulnerability reporting,
      Dependabot, and least-privilege GitHub Actions permissions (2026-09-21:
      ruleset "Protect main" — no deletion or force-push, pull request
      required, required checks `Gates (Linux)` / `Gates (macOS)` /
      `Gates (Windows)` with the branch up to date, review threads resolved,
      admin bypass only inside a pull request; secret scanning with push
      protection, Dependabot alerts and security updates, private
      vulnerability reporting all enabled; every workflow declares
      `permissions: contents: read`, `publish` alone holds `contents: write`).
- [x] Resolve self-hosted runner exposure (2026-09-21): Actions fork-PR
      approval is "Require approval for all external contributors" at both the
      repository and the organization; every workflow runs on GitHub-hosted
      runners (organization policy keeps public repositories off the
      self-hosted fleet), so no contributor PR code ever reaches a persistent
      machine and the fork-isolation `if:` guards were removed. Release builds
      and the `rule-control` gate run on ephemeral hosted runners too; the
      dedicated `metacodes-release` pool is no longer planned
      (`doc/RELEASE_RUNNER.md`).
- [x] Tag an immutable release and publish its checksums (2026-10-11, 0.5.0;
      0.1.0–0.4.0 before it). Planned as a `0.x.y-dev` pre-release; the
      release automation (`doc/RELEASE_AUTOMATION_DESIGN.md`) shipped stable
      releases instead. For 0.5.0, `release.yml` run 38111469169 succeeded on
      Linux, macOS and Windows: each staged the release unit and verified it
      natively (`zig build release:verify`, i.e.
      `scripts/verify_release_bundle.py --native`), ran the AgentCore gate and
      rebuilt the archive byte for byte. The published release carries the
      archives, `.sha256` sidecars and `metacodes-0.5.0-SHA256SUMS`, and
      GitHub reports it `immutable`. No unpacked *downloaded* archive was
      re-verified per platform. SBOM/provenance attestations remain a separate
      item.

Treating the public repository as release-approved requires all blocking owner
decisions, not merely a green build.
