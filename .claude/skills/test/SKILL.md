---
name: test
description: This skill should be used when the user asks to "write tests", "add tests", "test this", "add coverage", "create test cases", or wants vitest unit/integration tests for API routes or lib functions.
user-invocable: true
---

# Test

Write vitest unit and integration tests following existing test patterns.

## Workflow

Launch the **tester** subagent (`subagent_type: "tester"`) with the user's request. The tester writes tests using the project's established patterns: real SQLite via `node:sqlite`, Hono `app.request()`, and Zod schema validation.

### Invocation

Use the Agent tool with `subagent_type: "tester"`. Specify:

- Which route, function, or module to test
- Whether to focus on success paths, error paths, or both
- Any specific edge cases to cover

### What the tester does

1. Reads existing test patterns in `apps/api/src/**/*.test.ts`
2. Reads vitest config and mock-d1 setup
3. Writes tests using `app.request()` for integration tests and `createMockD1()` for DB
4. Runs `pnpm test` to verify all pass
5. Reports test results and coverage

### After the agent completes

Summarize: tests written, pass/fail status, coverage numbers, and any issues found.
