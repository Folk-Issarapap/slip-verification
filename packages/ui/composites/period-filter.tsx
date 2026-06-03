"use client"

import { useState } from "react"
import type { DateRange, Locale } from "react-day-picker"
import { Button } from "../components/button"
import { Calendar } from "../components/calendar"
import { Popover, PopoverContent, PopoverTrigger } from "../components/popover"

export type { Locale } from "react-day-picker"

// ── Types ─────────────────────────────────────────────────────────────────────

export type Period =
  | { kind: "preset"; preset: "7d" | "30d" | "90d" }
  | { kind: "custom"; from: Date; to: Date }

export interface PeriodLabels {
  custom?: string
  apply?: string
  clear?: string
  presets?: Partial<Record<"7d" | "30d" | "90d", string>>
}

const PRESET_DAYS: Record<"7d" | "30d" | "90d", number> = { "7d": 7, "30d": 30, "90d": 90 }

// ── Helpers ───────────────────────────────────────────────────────────────────

export function resolvePeriod(p: Period): { from: Date; to: Date; days: number } {
  if (p.kind === "custom") {
    const days = Math.round((p.to.getTime() - p.from.getTime()) / 86400000) + 1
    return { from: p.from, to: p.to, days }
  }
  const days = PRESET_DAYS[p.preset]
  // Build boundaries from local date components so that .toISOString().slice(0, 10)
  // yields the user's local calendar date rather than the UTC date (which is one
  // day behind for UTC+7 Bangkok users after midnight local time).
  const now = new Date()
  const y = now.getFullYear()
  const m = now.getMonth()
  const d = now.getDate()
  // to = end of today expressed as UTC midnight of the local date (safe for slice(0,10))
  const to = new Date(Date.UTC(y, m, d))
  // from = N-1 days before today in local calendar
  const from = new Date(Date.UTC(y, m, d - (days - 1)))
  return { from, to, days }
}

function formatShortDate(d: Date, localeCode?: string): string {
  return new Intl.DateTimeFormat(localeCode ?? "en", {
    day: "numeric",
    month: "short",
  }).format(d)
}

// ── Component ─────────────────────────────────────────────────────────────────

interface PeriodFilterProps {
  value: Period
  onChange: (next: Period) => void
  presets?: ("7d" | "30d" | "90d")[]
  labels?: PeriodLabels
  locale?: Locale
  intlLocale?: string
  className?: string
}

export function PeriodFilter({
  value,
  onChange,
  presets = ["7d", "30d", "90d"],
  labels,
  locale,
  intlLocale,
  className,
}: PeriodFilterProps) {
  const [pendingRange, setPendingRange] = useState<DateRange | undefined>(undefined)
  const [popoverOpen, setPopoverOpen] = useState(false)

  const isCustomActive = value.kind === "custom"

  // The current DateRange for the calendar (pending takes priority while open)
  const calendarSelected: DateRange | undefined = isCustomActive
    ? (pendingRange ?? { from: value.from, to: value.to })
    : pendingRange

  function handlePresetClick(preset: "7d" | "30d" | "90d") {
    setPendingRange(undefined)
    onChange({ kind: "preset", preset })
  }

  function handleApply() {
    if (pendingRange?.from && pendingRange?.to) {
      onChange({ kind: "custom", from: pendingRange.from, to: pendingRange.to })
    }
    setPopoverOpen(false)
  }

  function handleClear() {
    setPendingRange(undefined)
    const defaultPreset = presets.includes("30d") ? "30d" : presets[0]
    onChange({ kind: "preset", preset: defaultPreset })
    setPopoverOpen(false)
  }

  function handlePopoverOpenChange(open: boolean) {
    if (!open) setPendingRange(undefined)
    setPopoverOpen(open)
  }

  const customLabel = isCustomActive
    ? `${formatShortDate(value.from, intlLocale)} – ${formatShortDate(value.to, intlLocale)}`
    : (labels?.custom ?? "Custom")

  const activeButtonClass =
    "bg-foreground text-background hover:bg-foreground hover:text-background dark:hover:bg-foreground"
  const inactiveButtonClass = "text-muted-foreground"
  const customActiveClass = `${activeButtonClass} aria-expanded:bg-foreground aria-expanded:text-background`

  return (
    <div
      className={`inline-flex w-fit items-center gap-0.5 rounded-md border border-border/60 p-0.5${className ? ` ${className}` : ""}`}
    >
      {presets.map((preset) => (
        <Button
          key={preset}
          type="button"
          variant="ghost"
          size="sm"
          onClick={() => handlePresetClick(preset)}
          className={
            !isCustomActive && value.kind === "preset" && value.preset === preset
              ? activeButtonClass
              : inactiveButtonClass
          }
        >
          {labels?.presets?.[preset] ?? preset}
        </Button>
      ))}
      <Popover open={popoverOpen} onOpenChange={handlePopoverOpenChange}>
        <PopoverTrigger asChild>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className={isCustomActive ? customActiveClass : inactiveButtonClass}
          >
            {isCustomActive ? customLabel : (labels?.custom ?? "Custom")}
          </Button>
        </PopoverTrigger>
        <PopoverContent align="end" className="w-auto p-0">
          <Calendar
            mode="range"
            selected={calendarSelected}
            onSelect={setPendingRange}
            disabled={{ after: new Date() }}
            numberOfMonths={1}
            locale={locale}
          />
          <div className="flex items-center justify-between gap-2 border-t border-border px-3 py-2">
            <Button type="button" variant="ghost" size="sm" onClick={handleClear}>
              {labels?.clear ?? "Clear"}
            </Button>
            <Button
              type="button"
              size="sm"
              disabled={!pendingRange?.from || !pendingRange?.to}
              onClick={handleApply}
            >
              {labels?.apply ?? "Apply"}
            </Button>
          </div>
        </PopoverContent>
      </Popover>
    </div>
  )
}
