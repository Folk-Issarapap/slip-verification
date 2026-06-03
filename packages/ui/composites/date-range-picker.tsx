"use client"

import { CalendarIcon } from "lucide-react"
import * as React from "react"
import type { DateRange } from "react-day-picker"
import { Button } from "../components/button"
import { Calendar } from "../components/calendar"
import { Popover, PopoverContent, PopoverTrigger } from "../components/popover"
import { cn } from "../lib/utils"

export function formatIsoCalendarDate(date: Date): string {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, "0")
  const d = String(date.getDate()).padStart(2, "0")
  return `${y}-${m}-${d}`
}

function parseLocalCalendarDate(isoDate: string): Date {
  return new Date(`${isoDate.trim()}T00:00:00`)
}

/** Parse `YYYY-MM-DD..YYYY-MM-DD` stored in filter state / URL. */
export function parseIsoDateRangeValue(value: string | null | undefined): DateRange | undefined {
  if (!value) return undefined
  const [fromStr, toStr] = value.split("..", 2).map((s) => s.trim())
  const from = fromStr ? parseLocalCalendarDate(fromStr) : undefined
  const to = toStr ? parseLocalCalendarDate(toStr) : undefined
  if (!from && !to) return undefined
  return { from, to }
}

export function serializeIsoDateRangeValue(range: DateRange | undefined): string {
  if (!range?.from && !range?.to) return ""
  const from = range.from ? formatIsoCalendarDate(range.from) : ""
  const to = range.to ? formatIsoCalendarDate(range.to) : ""
  if (!from && !to) return ""
  return `${from}..${to}`
}

function formatRangeLabel(
  range: DateRange | undefined,
  placeholder: string,
  intlLocale?: string
): string {
  if (!range?.from) return placeholder
  const fmt = (d: Date) =>
    new Intl.DateTimeFormat(intlLocale ?? "en", {
      month: "short",
      day: "numeric",
      year: "numeric",
    }).format(d)
  if (range.from && range.to) return `${fmt(range.from)} – ${fmt(range.to)}`
  return `${fmt(range.from)} – …`
}

export interface DateRangePickerProps {
  value: string
  onChange: (value: string) => void
  placeholder?: string
  className?: string
  /** @default 2 — matches shadcn range picker layout */
  numberOfMonths?: number
  intlLocale?: string
  /** Hide inline clear control (parent provides reset) */
  showClear?: boolean
}

/**
 * shadcn/ui range date picker — single trigger + `Calendar mode="range"`.
 * Nested under other popovers (e.g. Advanced Filter): keep `modal={false}` so the
 * inner calendar does not dismiss on the first range click (Radix + focus trap).
 * @see https://ui.shadcn.com/docs/components/radix/date-picker#range-picker
 */
export function DateRangePicker({
  value,
  onChange,
  placeholder = "Pick a date range",
  className,
  numberOfMonths = 2,
  intlLocale,
  showClear = true,
}: DateRangePickerProps) {
  const selected = React.useMemo(() => parseIsoDateRangeValue(value), [value])
  const hasSelection = Boolean(selected?.from)

  const handleSelect = (range: DateRange | undefined) => {
    if (range === undefined) return
    if (!range.from) {
      onChange("")
      return
    }
    onChange(serializeIsoDateRangeValue(range))
  }

  const handleClear = () => {
    onChange("")
  }

  return (
    <Popover modal={false}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          data-empty={!hasSelection}
          className={cn(
            "h-8 w-full justify-start gap-2 font-normal data-[empty=true]:text-muted-foreground",
            className
          )}
        >
          <CalendarIcon className="size-3.5 shrink-0 text-muted-foreground" />
          <span className="truncate">{formatRangeLabel(selected, placeholder, intlLocale)}</span>
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-auto gap-0 p-0" align="start">
        <Calendar
          mode="range"
          defaultMonth={selected?.from}
          selected={selected}
          onSelect={handleSelect}
          numberOfMonths={numberOfMonths}
        />
        {showClear && hasSelection && (
          <div className="flex justify-end border-t border-border px-2 py-1.5">
            <Button type="button" variant="ghost" size="sm" onClick={handleClear}>
              Clear
            </Button>
          </div>
        )}
      </PopoverContent>
    </Popover>
  )
}
