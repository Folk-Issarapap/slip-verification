import { localCalendarRangeToUtcSqliteInclusiveBounds } from "./sqlite-bounds-from-local-cal"

/**
 * Reads a DataGrid / URL filter value for AdvancedFilterPopover `date-range` fields.
 * Values are stored as `YYYY-MM-DD..YYYY-MM-DD` in a single `string[]` entry; if the URL
 * layer split on commas (`2026-05-08,2026-05-11`), reconstruct the range.
 */
export function parseCalendarDateRangeFromFilterValues(values: string[] | undefined): {
  calendarFrom?: string
  calendarTo?: string
} {
  if (!values?.length) return {}

  let raw = values[0] ?? ""
  if (values.length >= 2 && !raw.includes("..")) {
    raw = `${values[0]}..${values[1]}`
  }

  if (!raw) return {}

  const [fromPart, toPart] = raw.split("..", 2).map((s) => s.trim())
  return {
    calendarFrom: fromPart || undefined,
    calendarTo: toPart || undefined,
  }
}

/** Local calendar pick → UTC naive SQLITE bounds for `created_at` TEXT filters. */
export function calendarDateRangeToApiBounds(values: string[] | undefined): {
  date_from?: string
  date_to?: string
} {
  const { calendarFrom, calendarTo } = parseCalendarDateRangeFromFilterValues(values)
  return localCalendarRangeToUtcSqliteInclusiveBounds(calendarFrom, calendarTo)
}
