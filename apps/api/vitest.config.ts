import { fileURLToPath } from "node:url"
import { defineConfig } from "vitest/config"

const configuredMaxWorkers = Number(process.env.VITEST_MAX_WORKERS)
const maxWorkers =
  Number.isFinite(configuredMaxWorkers) && configuredMaxWorkers > 0 ? configuredMaxWorkers : 4

function isIntegrationTarget(arg: string): boolean {
  const normalized = arg.replaceAll("\\", "/")
  return (
    normalized === "src/routes" ||
    normalized.startsWith("src/routes/") ||
    normalized.endsWith("/src/routes") ||
    normalized.includes("/src/routes/") ||
    normalized === "src/test/integration" ||
    normalized.startsWith("src/test/integration/") ||
    normalized.endsWith("/src/test/integration") ||
    normalized.includes("/src/test/integration/")
  )
}

if (process.env.BROPAY_RUN_INTEGRATION !== "1" && process.argv.some(isIntegrationTarget)) {
  throw new Error(
    [
      "API integration tests are opt-in.",
      "Set BROPAY_RUN_INTEGRATION=1 before running DB-backed route/integration tests.",
      "Use pnpm test or pnpm test:api:unit during normal development.",
    ].join(" ")
  )
}

// Scope coverage to the unit-owned surface (pure libs + middleware) when the
// dedicated `test:coverage:unit` script sets this flag. Route handlers,
// providers, and DB-backed integration flows are intentionally excluded from
// the unit-coverage gate — they are covered by the guarded integration suite.
const unitCoverage = process.env.BROPAY_UNIT_COVERAGE === "1"

const unitCoverageInclude = ["src/lib/**/*.ts", "src/middleware/**/*.ts"]

// `.tsx` files under lib (React email templates) are presentation/view
// boundaries, not unit-logic, and fall outside the `*.ts` unit scope. Exclude
// them explicitly so the unit-coverage denominator is deterministic.
const unitCoverageExclude = ["src/**/*.test.ts", "src/lib/**/*.tsx", "src/middleware/**/*.tsx"]

export default defineConfig({
  resolve: {
    alias: {
      "cloudflare:workers": fileURLToPath(
        new URL("./src/test/cloudflare-workers-shim.ts", import.meta.url)
      ),
    },
  },
  test: {
    globals: true,
    environment: "node",
    testTimeout: 15000,
    hookTimeout: 30000,
    pool: "forks",
    // Vitest 4 moved the old poolOptions.forks.maxForks setting to this
    // top-level option. Four workers is the default now that test DBs clone a
    // pre-migrated SQLite template instead of replaying migrations per DB.
    // Set VITEST_MAX_WORKERS=1 or 2 on constrained machines.
    maxWorkers,
    // Share module-level state across files within a worker — drops the per-file
    // transform + VM-instantiate cost (~50s saved on full-suite import phase,
    // makes single-file `vitest some.test.ts` runs much snappier in watch mode).
    // Safe because the Hono `app` (apps/api/src/index.ts) is stateless and every
    // test calls `createTestEnv()` for a fresh env + DB. Tests that need to mock
    // imports of already-cached modules must use `vi.doMock` + `vi.resetModules`
    // + dynamic `import()` in beforeEach — see `scheduled.test.ts` for the
    // canonical pattern. Top-level `vi.mock(...)` will silently no-op if the
    // target module was already loaded by an earlier test file in the worker.
    isolate: false,
    coverage: {
      provider: "v8",
      include: unitCoverage ? unitCoverageInclude : ["src/**/*.ts"],
      exclude: unitCoverage ? unitCoverageExclude : ["src/**/*.test.ts"],
      reporter: ["text", "lcov"],
      thresholds: unitCoverage
        ? {
            // Unit-owned surface (lib + middleware) gate. Measured: lines 97%,
            // functions 97%, branches ~85%.
            lines: 90,
            functions: 90,
            // Branches are ratcheted to the achieved floor (not 90) because the
            // remaining uncovered branches are not reachable from unit tests:
            //   - defensive `!result.ok` D1-failure paths — every dbAll/dbRun/
            //     dbFirst can return Err, but real SQLite never fails a
            //     well-formed query against existing tables;
            //   - `?? 0` guards on SQL aggregates wrapped in COALESCE/SUM that
            //     always return a row;
            //   - `e instanceof Error ? e.message : ...` else-arms (thrown
            //     values are always Error);
            //   - PBKDF2 key-cache eviction (crypto.ts) — needs 1001 derivations
            //     at 100k iterations, far past the test timeout;
            //   - presentational email-template branding branches;
            //   - a structurally-dead settlement-direction branch (the
            //     gl_activity view maps settlement entries to debit, so the
            //     credit+settlement combination is impossible).
            // Ratchet this upward as genuinely-reachable branches are covered.
            branches: 84,
          }
        : {
            lines: 82,
            functions: 78,
            // Remaining uncovered branches are defensive 500 paths (D1 failing
            // mid-operation after an existence check), profile avatar upload paths
            // (require R2 bucket), and other hard-to-test edge cases.
            branches: 63,
          },
    },
  },
})
