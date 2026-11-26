You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

Include, in this order:
1. **Original request & intent** — the user's original task and every explicit requirement/constraint, stated as literally as possible. PRESERVE THIS VERBATIM: on a long task this summary may itself be compacted again and again, so never paraphrase the goal away or let it drift — the resuming LLM must know EXACTLY what the user originally asked for.
2. Current progress and key decisions made
3. Important context, constraints, or user preferences
4. What remains to be done (clear next steps)
5. Any critical data, examples, or references needed to continue

Be concise and structured. The #1 priority is that a long, repeatedly-compacted task does not lose its original goal through summary-of-summary drift.
