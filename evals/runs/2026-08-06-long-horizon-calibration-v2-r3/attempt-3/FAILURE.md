# Calibration attempt 3 — fail-closed treatment attestation

Attempt 3 stopped after the first of 18 scheduled rollouts. No second paid
rollout was started, no promotion receipt was generated, and confirmatory
execution remains disabled.

## Observed rollout

- arm: `codex_style`
- task/trial: `80_lh_contract_recovery / 0`
- harness revision: `a5f21240a654ffd7b68f072071421334129e7b1f`
- execution: `exit_code=0`, 14/14 tool calls successful, zero reported harness,
  network, policy, or model-tool errors
- native wall time: 271.493 seconds
- usage: 39,858 input + 12,411 output + 316,864 cache-read = 369,133
  metered tokens
- cost: 0.4007982 USD
- checkpoint status: `invalid`, reason `treatment_activation_failed`

The durable checkpoint was published before the runner raised:

```text
treatment activation native event sequence is not contiguous:
expected 16, observed 0
```

## Root cause

The scored rollout legitimately appended three agent-loop invocations to one
`events.jsonl`. Native `sequence` is local to an invocation and therefore
restarted at zero for invocations 1 and 2. The treatment attester's synthetic
fixtures contained only one invocation, so it incorrectly enforced one global
sequence across the complete rollout.

After repairing that parser in development, replay exposed a second latent
contract mismatch: model-facing microcompaction had replaced older tool results
with an unauthenticated placeholder, while native events retained the original
result byte count and SHA-256. The checkpoint remains invalid; the paid result
is not retroactively admitted. The remediation preserves byte-count/SHA-256
commitments in cleared or truncated projections and rejects the legacy
placeholder in treatment evidence.

## Budget carryover

Historical carryover before attempt 3 was 3.3538134 USD and 2,219,293 tokens.
Including this invalid but paid rollout, the next attempt must start with:

```text
budget_used_cost_usd = 3.7546116
budget_used_tokens   = 2588426
```

## Evidence hashes

- checkpoint: `d705b415912dc1a83a8920deb1c12e0c7a47de9af9f21e310a1c19ce9277cb1c`
- native events: `68c97520352eeb71d452bfe5df763b3515579ca694a494477340ffc895cb273c`
- transcript: `a2d1a0a427b0bdc1bfb558277ce89f675cb40eca5417b4f5094e9e43ba3c350d`
- report: `fb2e9dc5a15fda0de8ca563924e0d3172c2b459c02f9436c4161dfef520e97a7`
- archived raw traces:
  `9ed5159fda1d66d422f14c39a4f2a728bf4ead16687248457ebe8f9dc1edb9f6`
- frozen dry-run plan (both copies):
  `f80f173c422f0d9b2e08e6fe965b4422af571ab1e7dab9c5a0712392a881c120`

This attempt is instrumentation/control evidence only. It provides no arm
effect estimate and cannot support a superiority claim.
