import { OpenAPIHono } from "@hono/zod-openapi"
import { apiReference } from "@scalar/hono-api-reference"
import { cors } from "hono/cors"
import type { Env } from "./lib/env"
import { validateEnv } from "./lib/env"
import { validationHook } from "./lib/hooks"
import {
  csrfProtection,
  etagHeaders,
  limit,
  reqId,
  reqTimeout,
  security,
  serverTiming,
  structuredLogger,
} from "./middleware/security"
import { utcDates } from "./middleware/utc-dates"

const app = new OpenAPIHono<{ Bindings: Env }>({ defaultHook: validationHook })

function splitAllowedOrigins(env: Env): string[] {
  return (
    env.ALLOWED_ORIGINS?.split(",")
      .map((s) => s.trim())
      .filter(Boolean) ?? []
  )
}

app.use("*", async (c, next) => {
  await next()
  if (c.res.status !== 304) return
  const origins = splitAllowedOrigins(c.env)
  const origin = c.req.header("origin") ?? ""
  if (origin && origins.includes(origin)) {
    c.header("Access-Control-Allow-Origin", origin)
  }
  c.header("Access-Control-Expose-Headers", "X-Request-Id")
})

// ── 1. Security (must be first) ───────────────────────────────────────────────
app.use("*", security)
app.use("*", reqId)
app.use("*", reqTimeout)
app.use("*", structuredLogger)
app.use("*", serverTiming)
app.use("*", limit)

// ── 2. CORS (must run before CSRF so OPTIONS preflight succeeds) ────────────
app.use("*", async (c, next) => {
  const origins = splitAllowedOrigins(c.env)
  return cors({
    origin: origins,
    allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowHeaders: [
      "Content-Type",
      "Authorization",
      "X-Request-Id",
      "Idempotency-Key",
    ],
    exposeHeaders: ["X-Request-Id"],
  })(c, next)
})

app.use("*", etagHeaders)
app.use("*", utcDates)
app.use("*", csrfProtection)

// ── 3. Health ─────────────────────────────────────────────────────────────────
app.get("/", async (c) => {
  let dbStatus = "ok"
  try {
    await c.env.DB.prepare("SELECT 1").first()
  } catch {
    dbStatus = "error"
  }
  return c.json(
    {
      data: {
        status: dbStatus === "ok" ? "ok" : "degraded",
        service: "api",
        version: "1.0.0",
        environment: c.env.ENVIRONMENT ?? "local",
        requestId: c.get("requestId"),
        db: dbStatus,
      },
    },
    200
  )
})

const createRouteGroup = () => new OpenAPIHono<{ Bindings: Env }>({ defaultHook: validationHook })
const sharedRoutes = createRouteGroup()

app.route("/", sharedRoutes)

const defineAdminClientRoutes = () => createRouteGroup().route("/", sharedRoutes)
const defineAppClientRoutes = () => createRouteGroup().route("/", sharedRoutes)

// ── 4. OpenAPI spec ───────────────────────────────────────────────────────────
app.get("/openapi.json", async (c, next) => {
  const env = c.env.ENVIRONMENT
  if (env === "production")
    return c.json({ error: { code: "NOT_FOUND", message: "Not found" } }, 404)
  return next()
})
app.doc("/openapi.json", {
  openapi: "3.1.0",
  info: {
    title: "App API",
    version: "1.0.0",
    description: "App API",
  },
  servers: [{ url: "http://localhost:8787", description: "Local dev" }],
})

// ── 5. Scalar docs (staging + local only) ────────────────────────────────────
app.get("/docs", async (c, next) => {
  const env = c.env.ENVIRONMENT
  if (env === "production")
    return c.json({ error: { code: "NOT_FOUND", message: "Not found" } }, 404)
  return next()
})
app.get(
  "/docs",
  apiReference({
    theme: "saturn",
    url: "/openapi.json",
  })
)

// ── 6. Fallback ──────────────────────────────────────────────────────────────
app.notFound((c) => c.json({ error: { code: "NOT_FOUND", message: "Route not found" } }, 404))

app.onError((err, c) => {
  const requestId = c.get("requestId")

  if ("status" in err && typeof err.status === "number" && err.status >= 400 && err.status < 500) {
    return c.json(
      { error: { code: "FORBIDDEN", message: err.message || "Request rejected" } },
      err.status as 403
    )
  }

  console.error(
    JSON.stringify({
      level: "error",
      requestId,
      method: c.req.method,
      path: c.req.path,
      error: err.message,
      stack: err.stack,
      env: (c.env as { ENVIRONMENT?: string }).ENVIRONMENT ?? "local",
    })
  )
  return c.json({ error: { code: "INTERNAL_ERROR", message: "Internal server error" } }, 500)
})

export { app }

let _validatedEnv: Env | null = null
let _envError: string | null = null

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Response | Promise<Response> {
    if (_validatedEnv === null && _envError === null) {
      try {
        _validatedEnv = validateEnv(env as unknown as Record<string, unknown>)
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err)
        _envError = message
        console.error(
          JSON.stringify({
            level: "error",
            event: "env_validation_failed",
            message,
          })
        )
      }
    }
    if (_envError !== null) {
      return new Response(
        JSON.stringify({
          error: { code: "MISCONFIGURED", message: `Server misconfigured: ${_envError}` },
        }),
        {
          status: 503,
          headers: { "Content-Type": "application/json" },
        }
      )
    }
    return app.fetch(request, _validatedEnv ?? env, ctx)
  }
}

export type AdminAppType = ReturnType<typeof defineAdminClientRoutes>
export type AppClientType = ReturnType<typeof defineAppClientRoutes>
