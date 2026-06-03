import type { MiddlewareHandler } from "hono"
import { bodyLimit } from "hono/body-limit"
import { csrf } from "hono/csrf"
import { etag } from "hono/etag"
import { HTTPException } from "hono/http-exception"
import { requestId } from "hono/request-id"
import { secureHeaders } from "hono/secure-headers"
import { timeout } from "hono/timeout"
import { timing } from "hono/timing"

export const security = secureHeaders({
  strictTransportSecurity: "max-age=63072000; includeSubDomains; preload",
  crossOriginResourcePolicy: "cross-origin",
  contentSecurityPolicy: undefined,
  xFrameOptions: "DENY",
})

export const reqId = requestId({
  generator: (c) => c.req.header("cf-ray") ?? crypto.randomUUID(),
})

export const reqTimeout = timeout(
  10_000,
  (c) =>
    new HTTPException(408, {
      message: `Request timed out. Request-Id: ${c.get("requestId")}`,
    })
)

const SENSITIVE_PATTERNS = /password|token|secret|auth|card|email|api[-_]?key|key$/i
const CHECKOUT_SECRET_PATH_RE = /\/v1\/(en|th)\/pay\/([^/?#]+)(\/status)?/g

function scrubSensitive(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const key of Object.keys(obj)) {
    if (SENSITIVE_PATTERNS.test(key)) {
      out[key] = "[REDACTED]"
    } else if (typeof obj[key] === "object" && obj[key] !== null && !Array.isArray(obj[key])) {
      out[key] = scrubSensitive(obj[key] as Record<string, unknown>)
    } else {
      out[key] = obj[key]
    }
  }
  return out
}

function redactSensitivePath(path: string): string {
  return path.replace(
    CHECKOUT_SECRET_PATH_RE,
    (_match, lang: string, _secret: string, status = "") =>
      `/v1/${lang}/pay/[client_secret]${status}`
  )
}

/**
 * Structured logger — captures:
 * - Every request: method, path, status, duration, requestId, env
 * - Request body (POST/PUT/PATCH): logged in non-production for debugging.
 *   In production, body is omitted to avoid logging PII.
 * - 4xx responses: logged as warnings with body snapshot
 * - 5xx responses: logged as errors (also caught by onError for stack trace)
 */
export const structuredLogger: MiddlewareHandler = async (c, next) => {
  const start = Date.now()
  const env = (c.env as { ENVIRONMENT?: string }).ENVIRONMENT ?? "local"
  const isProd = env === "production"

  // Capture request body before it's consumed — only for mutating methods
  let requestBody: unknown
  const method = c.req.method
  if (["POST", "PUT", "PATCH"].includes(method)) {
    const contentType = c.req.header("content-type") ?? ""
    if (contentType.includes("multipart/form-data")) {
      // Do not read binary / large bodies — was logging full image as garbage
      // and bloating logs on avatar uploads.
      requestBody = "[multipart body omitted — not logged]"
    } else {
      try {
        const cloned = c.req.raw.clone()
        const text = await cloned.text()
        if (text) {
          try {
            requestBody = JSON.parse(text)
          } catch {
            requestBody = text
          }
          if (typeof requestBody === "object" && requestBody !== null) {
            requestBody = scrubSensitive(requestBody as Record<string, unknown>)
          }
        }
      } catch {
        requestBody = "[unreadable]"
      }
    }
  }

  await next()

  const ms = Date.now() - start
  const status = c.res.status
  const requestId = c.get("requestId")

  const base = {
    requestId,
    method,
    path: redactSensitivePath(c.req.path),
    status,
    durationMs: ms,
    env,
    // Include body in dev/staging; omit in production
    ...(requestBody !== undefined && !isProd ? { requestBody } : {}),
  }

  if (status >= 500) {
    // 5xx — error (also logged with stack in onError)
    console.error(JSON.stringify({ level: "error", ...base }))
  } else if (status >= 400) {
    // 4xx — warning: log with response body snapshot for debugging
    let responseBody: unknown = "[unread]"
    try {
      responseBody = await c.res.clone().json()
    } catch {
      responseBody = await c.res
        .clone()
        .text()
        .catch(() => "[unread]")
    }
    console.warn(JSON.stringify({ level: "warn", ...base, responseBody }))
  } else {
    // 2xx/3xx — info
    console.log(JSON.stringify({ level: "info", ...base }))
  }
}

// ── Built-in Hono middleware ─────────────────────────────────────────────────

// 8 MB — 5 MB avatar (handler cap) + multipart overhead; 6 MB was too tight → 413
// before the handler runs. Settlements still cap file size in route handlers.
export const limit = bodyLimit({ maxSize: 8 * 1024 * 1024 })

export const csrfProtection = csrf({
  origin: (origin, c) => {
    // Trim per entry — `ALLOWED_ORIGINS="https://a.com, https://b.com"` would
    // otherwise silently fail for the second origin (leading space).
    const allowed =
      (c.env as { ALLOWED_ORIGINS?: string }).ALLOWED_ORIGINS?.split(",")
        .map((s) => s.trim())
        .filter(Boolean) ?? []
    return allowed.includes(origin)
  },
})

export const etagHeaders = etag()

export const serverTiming = timing()
