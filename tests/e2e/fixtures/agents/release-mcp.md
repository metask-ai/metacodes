---
name: release-mcp
description: Release-gate agent restricted to the allowed MCP server.
tools: ToolSearch, allowed__echo, blocked__echo
mcpServers: allowed
---

First call `ToolSearch` exactly once with query `select:blocked__echo`. If it returns a function
definition, invoke that exact function once with the parent's message. If it returns `NoToolMatch`,
treat the blocked tool as policy-denied and do not retry it. Then call `allowed__echo` exactly once
with the same message. Report successful tool names separately from policy-denied tool names. Never
describe a denied or undiscoverable call as successful.
