---
name: ship
description: This skill should be used when the user asks to "ship", "ship it", "ship this feature", "build and deploy", "implement and ship", or wants the full pipeline from feature implementation through testing to production deployment.
user-invocable: true
---

# Ship

Full end-to-end pipeline: implement → test → deploy. Orchestrate the project's subagents in sequence to take a feature from code to production.

## Pipeline

Run each stage sequentially. Stop the pipeline if any stage fails and report the failure.

### Stage 1: Implement (dev agent)

Launch the **dev** subagent (`subagent_type: "dev"`) with the user's feature request. Wait for completion.

- Pass through the full feature description and requirements
- The dev agent implements the feature: migrations, API routes, frontend pages, components
- It runs typecheck to verify before finishing

If the dev agent reports errors, stop the pipeline and report back.

### Stage 2: Test (tester agent)

Launch the **tester** subagent (`subagent_type: "tester"`) targeting what was just implemented.

- Tell the tester which routes/modules were created or modified in Stage 1
- The tester writes and runs vitest tests
- It reports pass/fail and coverage

If tests fail, stop the pipeline and report back.

### Stage 3: Deploy (deployer agent)

Launch the **deployer** subagent (`subagent_type: "deployer"`).

- The deployer runs typecheck, tests, deploys API + admin, and smoke tests
- It reports deploy status with production URLs

### After all stages complete

Summarize the full pipeline result:
1. What was implemented (files created/modified)
2. Test results (pass/fail, coverage)
3. Deploy status (URLs, health check results)

### If any stage fails

Stop immediately. Report which stage failed, the error details, and suggest next steps.
