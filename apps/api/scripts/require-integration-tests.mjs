const allowIntegration = process.env.BROPAY_RUN_INTEGRATION === "1"

if (!allowIntegration) {
  console.error(
    [
      "API integration tests are opt-in.",
      "",
      "Use unit tests during normal development:",
      "  pnpm test",
      "",
      "Run DB-backed integration tests only when intentional:",
      "  BROPAY_RUN_INTEGRATION=1 pnpm test:api:integration",
      "  BROPAY_RUN_INTEGRATION=1 pnpm --filter api run test:integration",
    ].join("\n")
  )
  process.exit(1)
}
