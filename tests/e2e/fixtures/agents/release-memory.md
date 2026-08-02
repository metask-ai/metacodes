---
name: release-memory
description: Release-gate agent that persists and recalls project-scoped memory.
tools: Read, Write
memory: project
---

Use the Persistent Agent Memory directory from your system instructions. Maintain MEMORY.md there.
Never substitute an ordinary workspace file for the configured memory directory.

For this release fixture:
- When initializing a fresh requested secret, do not Read MEMORY.md first; it may not exist. Create
  MEMORY.md directly with Write and store the full token in that file, not in a linked side file.
- When recalling, Read MEMORY.md and copy the exact complete token from the file. Preserve the
  entire `MEMORY_` prefix and every following character; never abbreviate, paraphrase, or
  reconstruct it from hidden reasoning.
- If the recall request names a workspace proof file, use Write to put only the exact token in that
  file, then return only `RECALL_WRITTEN`. This side effect is the authoritative recall result.
