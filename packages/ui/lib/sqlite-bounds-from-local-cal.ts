/** `YYYY-MM-DD` only — used for picker / URL persisted values */
const LOCAL_CALENDAR = /^\d{4}-\d{2}-\d{2}$/

/**
 * Format a JS `Date` (absolute instant) as UTC wall-clock `YYYY-MM-DD HH:MM:SS`
 * comparable to SQLite `audit_logs.created_at` / `datetime('now')`-style TEXT.
 */
export function utcInstantToSqliteUtcDatetime(date: Date): string {
  const y = date.getUTCFullYear()
  const m = String(date.getUTCMonth() + 1).padStart(2, "0")
  const d = String(date.getUTCDate()).padStart(2, "0")
  const hh = String(date.getUTCHours()).padStart(2, "0")
  const mm = String(date.getUTCMinutes()).padStart(2, "0")
  const ss = String(date.getUTCSeconds()).padStart(2, "0")
  return `${y}-${m}-${d} ${hh}:${mm}:${ss}`
}

/**
 * Turns **local-calendar** `[from,to]` IDs from the AdvancedFilter date-range picker
 * into inclusive UTC SQLITE bounds aligned with rows stored as UTC naive TEXT.
 *
 * Without this, the API compares `YYYY-MM-DD 23:59:59` as if it were UTC, which leaks
 * the next calendar day when the viewer is east of UTC (e.g. local 13 May end still
 * includes UTC instants rendered as **14 May** locally).
 */
export function localCalendarRangeToUtcSqliteInclusiveBounds(
  calendarFrom?: string | null,
  calendarTo?: string | null
): { date_from?: string; date_to?: string } {
  const out: { date_from?: string; date_to?: string } = {}
  if (!calendarFrom && !calendarTo) return out

  if (calendarFrom) {
    const s = calendarFrom.trim()
    if (LOCAL_CALENDAR.test(s)) {
      const [y, mo, da] = s.split("-").map(Number)
      const startLocal = new Date(y, mo - 1, da, 0, 0, 0, 0)
      out.date_from = utcInstantToSqliteUtcDatetime(startLocal)
    }
  }
  if (calendarTo) {
    const s = calendarTo.trim()
    if (LOCAL_CALENDAR.test(s)) {
      const [y, mo, da] = s.split("-").map(Number)
      const endLocal = new Date(y, mo - 1, da, 23, 59, 59, 999)
      out.date_to = utcInstantToSqliteUtcDatetime(endLocal)
    }
  }
  return out
}
