import type { MiddlewareHandler } from "hono"

/**
 * SQLite datetime pattern: "YYYY-MM-DD HH:MM:SS"
 * D1's datetime('now') returns UTC without a timezone suffix.
 * This middleware appends "Z" to all matching strings in JSON responses
 * so clients parse them as UTC, not local time.
 */
const SQLITE_DATETIME_RE = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/

function fixDates(value: unknown): unknown {
  if (typeof value === "string" && SQLITE_DATETIME_RE.test(value)) {
    return `${value.replace(" ", "T")}Z`
  }
  if (Array.isArray(value)) {
    return value.map(fixDates)
  }
  if (value !== null && typeof value === "object") {
    const result: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(value)) {
      result[k] = fixDates(v)
    }
    return result
  }
  return value
}

/**
 * Middleware that transforms SQLite datetime strings in JSON responses
 * from "YYYY-MM-DD HH:MM:SS" to "YYYY-MM-DDTHH:MM:SSZ" (ISO 8601 UTC).
 *
 * Only processes application/json responses.
 */
export const utcDates: MiddlewareHandler = async (c, next) => {
  await next()

  const ct = c.res.headers.get("content-type") ?? ""
  if (!ct.includes("application/json")) return

  try {
    const body = await c.res.json()
    const fixed = fixDates(body)
    c.res = c.json(fixed as Record<string, unknown>, c.res.status as 200)
  } catch {
    // If JSON parsing fails, leave the response untouched
  }
}
