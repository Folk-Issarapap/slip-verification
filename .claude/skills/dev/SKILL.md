---
name: dev
description: This skill should be used when the user asks to "build a feature", "add a page", "create a route", "implement", "add component", "scaffold", or wants end-to-end feature development across API and frontend.
user-invocable: true
---

# Dev

Implement features end-to-end following project patterns.

## Workflow

Launch the **dev** subagent (`subagent_type: "dev"`) with the user's request. The dev agent handles full-stack implementation: API routes, DB migrations, frontend pages, and UI components.

### Invocation

Use the Agent tool with `subagent_type: "dev"`. Include the full context of what the user wants built. Be specific about:

- What entity/feature to create
- Any requirements or constraints mentioned
- Whether it's API-only, frontend-only, or full-stack

### What the dev agent does

1. Reads CLAUDE.md and existing patterns
2. Implements the feature (migrations, API routes, frontend pages, components)
3. Runs typecheck across all packages
4. Runs tests if API code was touched
5. Reports what was created/modified

### After the agent completes

Summarize what was built: files created/modified, any issues encountered, and next steps if applicable.
