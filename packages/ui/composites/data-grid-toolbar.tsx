"use client"

import { ChevronDownIcon, PlusIcon, SlidersHorizontalIcon } from "lucide-react"
import * as React from "react"
import { Button } from "../components/button"
import { Checkbox } from "../components/checkbox"
import { Input } from "../components/input"
import { Label } from "../components/label"
import { Popover, PopoverContent, PopoverTrigger } from "../components/popover"
import { cn } from "../lib/utils"
import { DateRangePicker } from "./date-range-picker"

// ─── Types ─────────────────────────────────────────────────────────────────────

export interface QuickFilterChipOption {
  value: string
  label: string
  count?: number
}

export interface QuickFilterChipsProps {
  options: QuickFilterChipOption[]
  value: string
  onChange: (value: string) => void
  /**
   * "inline" (default) renders every option as a horizontal chip — best for wide toolbars.
   * "pill" collapses into a single dropdown trigger — best for narrow contexts (sub-tabs,
   * inside grids with sidebars). The popover preserves counts.
   */
  variant?: "inline" | "pill"
  /** Label prefix for the pill trigger when a value is selected (e.g. "Status: Succeeded"). Defaults to "Status". */
  label?: string
  className?: string
}

export interface PinnableFilterChipProps<T extends string = string> {
  label: string
  value?: T | null
  valueLabel?: string
  options: Array<{ value: T; label: string }>
  onChange: (value: T | null) => void
  className?: string
}

export type FilterFieldDef =
  | {
      kind: "multi-select"
      name: string
      label: string
      options: Array<{ value: string; label: string; count?: number }>
    }
  | {
      kind: "select"
      name: string
      label: string
      placeholder?: string
      options: Array<{ value: string; label: string }>
    }
  | { kind: "date-range"; name: string; label: string; placeholder?: string }
  | { kind: "number-range"; name: string; label: string; placeholder?: string }

export type AdvancedFilterValue = Record<string, string[]>

export interface AdvancedFilterPopoverProps {
  fields: FilterFieldDef[]
  value: AdvancedFilterValue
  onApply: (next: AdvancedFilterValue) => void
  triggerLabel?: string
  className?: string
}

export interface ActiveFilterBadgeProps {
  count: number
  className?: string
}

export interface DataGridToolbarProps {
  children: React.ReactNode
  className?: string
}

// ─── ActiveFilterBadge ─────────────────────────────────────────────────────────

export function ActiveFilterBadge({ count, className }: ActiveFilterBadgeProps) {
  if (count <= 0) return null
  return (
    <span
      className={cn(
        "inline-flex size-5 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground tabular-nums",
        className
      )}
    >
      {count}
    </span>
  )
}

// ─── Chip active-state class (overlay on Button variant="outline") ───────────

const CHIP_ACTIVE_CLASS =
  "border-primary bg-primary/5 font-medium text-foreground hover:bg-primary/5"
const CHIP_INACTIVE_CLASS = "text-muted-foreground"

function chipClassName(isActive: boolean, extra?: string) {
  return cn(isActive ? CHIP_ACTIVE_CLASS : CHIP_INACTIVE_CLASS, extra)
}

// ─── QuickFilterChips ──────────────────────────────────────────────────────────

export function QuickFilterChips({
  options,
  value,
  onChange,
  variant = "inline",
  label = "Status",
  className,
}: QuickFilterChipsProps) {
  if (variant === "pill") {
    return (
      <QuickFilterPill
        options={options}
        value={value}
        onChange={onChange}
        label={label}
        className={className}
      />
    )
  }
  return (
    <div className={cn("flex items-center gap-2 overflow-x-auto no-scrollbar", className)}>
      {options.map((option) => {
        const isActive = option.value === value
        return (
          <Button
            key={option.value}
            type="button"
            variant="outline"
            onClick={() => onChange(option.value)}
            className={chipClassName(isActive)}
          >
            {option.label}
            {option.count !== undefined && (
              <span className="text-muted-foreground tabular-nums">{option.count}</span>
            )}
          </Button>
        )
      })}
    </div>
  )
}

function QuickFilterPill({
  options,
  value,
  onChange,
  label,
  className,
}: {
  options: QuickFilterChipOption[]
  value: string
  onChange: (value: string) => void
  label: string
  className?: string
}) {
  const [open, setOpen] = React.useState(false)
  const selected = options.find((o) => o.value === value)
  // Treat the first option as the "all/cleared" state for trigger labelling.
  const isCleared = !selected || selected.value === options[0]?.value
  const triggerLabel = isCleared ? label : `${label}: ${selected.label}`

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="outline" className={chipClassName(!isCleared, className)}>
          {triggerLabel}
          <ChevronDownIcon className="size-3 text-muted-foreground" />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-56 gap-0 p-1">
        <div className="flex flex-col">
          {options.map((option) => {
            const isSelected = option.value === value
            return (
              <Button
                key={option.value}
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => {
                  onChange(option.value)
                  setOpen(false)
                }}
                className={cn(
                  "h-auto w-full justify-start gap-2 rounded-sm px-2 py-1.5 font-normal",
                  isSelected && "font-medium text-foreground"
                )}
              >
                <span className="flex-1 text-left">{option.label}</span>
                {option.count !== undefined && (
                  <span className="tabular-nums text-muted-foreground">{option.count}</span>
                )}
              </Button>
            )
          })}
        </div>
      </PopoverContent>
    </Popover>
  )
}

// ─── PinnableFilterChip ────────────────────────────────────────────────────────

export function PinnableFilterChip<T extends string = string>({
  label,
  value,
  valueLabel,
  options,
  onChange,
  className,
}: PinnableFilterChipProps<T>) {
  const [open, setOpen] = React.useState(false)
  const hasValue = value != null && value !== ""

  const displayLabel = hasValue ? `${label}: ${valueLabel ?? value}` : undefined

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="outline" className={chipClassName(hasValue, className)}>
          {!hasValue && <PlusIcon className="size-3" />}
          {displayLabel ?? label}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-44 gap-0 p-1">
        <div className="flex flex-col">
          {options.map((option) => {
            const isSelected = option.value === value
            return (
              <Button
                key={option.value}
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => {
                  onChange(isSelected ? null : (option.value as T))
                  setOpen(false)
                }}
                className={cn(
                  "h-auto w-full justify-start gap-2 rounded-sm px-2 py-1.5 font-normal",
                  isSelected && "font-medium text-primary"
                )}
              >
                {option.label}
              </Button>
            )
          })}
          {hasValue && (
            <>
              <div className="my-1 h-px bg-border" />
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => {
                  onChange(null)
                  setOpen(false)
                }}
                className="h-auto w-full justify-start rounded-sm px-2 py-1.5 font-normal text-muted-foreground hover:text-foreground"
              >
                Clear
              </Button>
            </>
          )}
        </div>
      </PopoverContent>
    </Popover>
  )
}

// ─── AdvancedFilterPopover ─────────────────────────────────────────────────────

function MultiSelectField({
  field,
  staged,
  onToggle,
}: {
  field: Extract<FilterFieldDef, { kind: "multi-select" }>
  staged: string[]
  onToggle: (value: string) => void
}) {
  return (
    <div className="flex flex-col gap-1.5">
      {field.options.map((option) => {
        const checked = staged.includes(option.value)
        const id = `dgt-${field.name}-${option.value}`
        return (
          <Label
            key={option.value}
            htmlFor={id}
            className="flex cursor-pointer items-center gap-2 rounded-sm px-0.5 py-0.5 font-normal transition-colors hover:bg-muted/60"
          >
            <Checkbox id={id} checked={checked} onCheckedChange={() => onToggle(option.value)} />
            <span className="flex-1">{option.label}</span>
            {option.count !== undefined && (
              <span className="tabular-nums text-muted-foreground">{option.count}</span>
            )}
          </Label>
        )
      })}
    </div>
  )
}

function SelectField({
  field,
  stagedValue,
  onChange,
}: {
  field: Extract<FilterFieldDef, { kind: "select" }>
  stagedValue: string
  onChange: (value: string) => void
}) {
  return (
    <div className="flex flex-col gap-1">
      {field.options.map((option) => {
        const isSelected = stagedValue === option.value
        return (
          <Button
            key={option.value}
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => onChange(isSelected ? "" : option.value)}
            className={cn(
              "h-auto w-full justify-start gap-2 rounded-sm px-1.5 py-1 font-normal",
              isSelected && "font-medium text-primary"
            )}
          >
            {option.label}
          </Button>
        )
      })}
    </div>
  )
}

function DateRangeField({
  field,
  stagedValue,
  onChange,
}: {
  field: Extract<FilterFieldDef, { kind: "date-range" }>
  stagedValue: string
  onChange: (value: string) => void
}) {
  return (
    <DateRangePicker
      value={stagedValue}
      onChange={onChange}
      placeholder={field.placeholder ?? "Pick a date range"}
      numberOfMonths={2}
    />
  )
}

function NumberRangeField({
  field,
  stagedValue,
  onChange,
}: {
  field: Extract<FilterFieldDef, { kind: "number-range" }>
  stagedValue: string
  onChange: (value: string) => void
}) {
  return (
    <Input
      value={stagedValue}
      onChange={(e) => onChange(e.target.value)}
      placeholder={field.placeholder ?? "Enter range"}
      type="text"
      inputMode="numeric"
    />
  )
}

export function AdvancedFilterPopover({
  fields,
  value,
  onApply,
  triggerLabel = "Filters",
  className,
}: AdvancedFilterPopoverProps) {
  const [open, setOpen] = React.useState(false)
  // Staged state — only propagates on Apply
  const [staged, setStaged] = React.useState<Record<string, unknown>>(value)

  // Sync staged when popover opens so it reflects current applied value
  React.useEffect(() => {
    if (open) setStaged(value)
  }, [open, value])

  const activeCount = Object.keys(value).filter((k) => {
    const v = value[k]
    if (Array.isArray(v)) return v.length > 0
    return v != null && v !== ""
  }).length

  function getStagedArray(name: string): string[] {
    const v = staged[name]
    return Array.isArray(v) ? (v as string[]) : []
  }

  /** URL-backed filter state uses `string[]`; staged edits use plain strings for scalar fields */
  function getStagedSingleValue(name: string): string {
    const v = staged[name]
    if (typeof v === "string") return v
    if (Array.isArray(v)) {
      const first = v[0]
      return typeof first === "string" ? first : ""
    }
    return ""
  }

  function toggleMultiSelect(name: string, val: string) {
    setStaged((prev) => {
      const current = Array.isArray(prev[name]) ? (prev[name] as string[]) : []
      const next = current.includes(val) ? current.filter((x) => x !== val) : [...current, val]
      return { ...prev, [name]: next }
    })
  }

  function setFieldValue(name: string, val: string) {
    setStaged((prev) => ({ ...prev, [name]: val }))
  }

  function handleClearAll() {
    setStaged({})
  }

  function handleApply() {
    // Strip empty values before propagating. Normalize to string[] (FilterState shape)
    // by wrapping single-string select values as one-element arrays.
    const cleaned: AdvancedFilterValue = {}
    for (const [k, v] of Object.entries(staged)) {
      if (Array.isArray(v) && v.length > 0) {
        cleaned[k] = v.filter((x): x is string => typeof x === "string" && x !== "")
      } else if (typeof v === "string" && v !== "") {
        cleaned[k] = [v]
      }
    }
    onApply(cleaned)
    setOpen(false)
  }

  function handleCancel() {
    setOpen(false)
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          className={chipClassName(activeCount > 0, className)}
        >
          <SlidersHorizontalIcon className="size-3" />
          {triggerLabel}
          <ActiveFilterBadge count={activeCount} />
        </Button>
      </PopoverTrigger>
      <PopoverContent
        align="end"
        className="w-[640px] max-w-[calc(100vw-2rem)] gap-0 p-4"
        sideOffset={6}
      >
        <div className="grid grid-cols-2 gap-x-4 gap-y-4">
          {fields.map((field) => (
            <div key={field.name} className="flex flex-col gap-1.5">
              <span className="text-xs font-medium">{field.label}</span>
              {field.kind === "multi-select" && (
                <MultiSelectField
                  field={field}
                  staged={getStagedArray(field.name)}
                  onToggle={(val) => toggleMultiSelect(field.name, val)}
                />
              )}
              {field.kind === "select" && (
                <SelectField
                  field={field}
                  stagedValue={getStagedSingleValue(field.name)}
                  onChange={(val) => setFieldValue(field.name, val)}
                />
              )}
              {field.kind === "date-range" && (
                <DateRangeField
                  field={field}
                  stagedValue={getStagedSingleValue(field.name)}
                  onChange={(val) => setFieldValue(field.name, val)}
                />
              )}
              {field.kind === "number-range" && (
                <NumberRangeField
                  field={field}
                  stagedValue={getStagedSingleValue(field.name)}
                  onChange={(val) => setFieldValue(field.name, val)}
                />
              )}
            </div>
          ))}
        </div>

        <div className="mt-4 flex items-center justify-between border-t border-border/60 pt-3">
          <Button type="button" variant="ghost" size="sm" onClick={handleClearAll}>
            Clear all
          </Button>
          <div className="flex items-center gap-2">
            <Button type="button" variant="outline" size="sm" onClick={handleCancel}>
              Cancel
            </Button>
            <Button type="button" size="sm" onClick={handleApply}>
              Apply filters
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  )
}

// ─── DataGridToolbar + DataGridToolbarSpacer ───────────────────────────────────

export function DataGridToolbarSpacer() {
  return <div className="ml-auto" />
}

export function DataGridToolbar({ children, className }: DataGridToolbarProps) {
  return (
    <div
      className={cn(
        "flex flex-wrap items-center gap-2 border-b border-border bg-card px-3 py-2",
        className
      )}
    >
      {children}
    </div>
  )
}
