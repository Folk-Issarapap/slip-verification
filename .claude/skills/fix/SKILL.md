---
name: fix
description: This skill should be used when the user asks to "fix a bug", "debug", "investigate", "why is this broken", "trace the error", "diagnose", or reports something not working. Launches the debugger agent to trace and diagnose root cause.
user-invocable: true
---

# Fix

Diagnose bugs by tracing the request flow and identifying root cause.

## Workflow

Launch the **debugger** subagent (`subagent_type: "debugger"`) with the user's bug report or symptoms. The debugger traces the issue through middleware, route handlers, and DB queries.

### Invocation

Use the Agent tool with `subagent_type: "debugger"`. Include all available context:

- What the user expected vs what happened
- Error messages, status codes, or screenshots
- Which endpoint, page, or feature is affected
- Steps to reproduce if known

### What the debugger does

1. Reproduces or understands the symptom
2. Traces the request through middleware, handlers, and DB
3. Checks types with typecheck
4. May start dev server and curl endpoints
5. Identifies the exact file:line and root cause

### After the agent completes

The debugger reports diagnosis only -- it does NOT edit files. Relay the root cause and suggested fix to the user. If the user wants to apply the fix, hand off to the `dev` agent.
