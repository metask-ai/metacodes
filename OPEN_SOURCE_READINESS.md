# Open-source readiness

The repository is prepared for review but is **not approved for public visibility**.

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
  checkout; nine installed-checkout tests remain an explicit external-only gate.

## Blocking owner decisions

- [ ] Select and add the metacodes project license. TinyKG's Apache-2.0 dependency
      declaration does not license metacodes.
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
- [ ] Enable branch protection, required CI, private vulnerability reporting,
      Dependabot, and least-privilege GitHub Actions permissions.
- [ ] Resolve self-hosted runner exposure before visibility flips: keep the
      fork-PR isolation guard on every `pull_request` job, set Actions fork
      approval to "Require approval for all outside collaborators", and either
      move public-facing CI to GitHub-hosted or ephemeral runners or record an
      explicit owner decision that persistent runners may execute contributor
      PR code. Give the `rule-control` release gate a runner label separate
      from the PR pool.
- [ ] Tag an immutable pre-release and publish its checksums/SBOM/provenance.

Removing this warning or making the repository public requires all blocking owner
decisions, not merely a green build.
