# Open-source readiness

The repository is prepared for review but is **not approved for public visibility**.

## Completed

- standalone Git history with `main` as the primary branch;
- independent build/package root and repository documentation;
- public API and embedding-surface inventory;
- TinyKG source removed and replaced by an explicit binary attestation contract;
- local artifacts, evaluation runs, stores, and binaries ignored;
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
- [ ] Review `THIRD_PARTY_NOTICES.md` and every distributed asset/license.
- [ ] Run native ReleaseSafe tests and AgentCore source-free consumer gates on the
      supported matrix.
- [ ] Verify public examples use placeholders and no paid endpoint by default.
- [ ] Enable branch protection, required CI, private vulnerability reporting,
      Dependabot, and least-privilege GitHub Actions permissions.
- [ ] Tag an immutable pre-release and publish its checksums/SBOM/provenance.

Removing this warning or making the repository public requires all blocking owner
decisions, not merely a green build.
