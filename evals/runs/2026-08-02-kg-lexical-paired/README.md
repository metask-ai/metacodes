# TinyKG lexical-bridge paired smoke

This directory records two valid paired GLM-5.2 trials for the lexical-bridge
mechanism. Baseline trustworthy success was 0/2 and candidate success was 2/2,
but the sample is intentionally tiny: McNemar exact `p=0.5`. Treat this as
mechanism evidence and a reproducible harness fixture, not as a statistically
supported product-performance claim.

The JSONL `artifacts` fields preserve the original capture locations for audit
provenance. Those local paths are not portable and the large raw run directories
are not part of this snapshot; the scored outcomes, identities, metrics and
comparison inputs are contained in the checked-in JSONL records.
