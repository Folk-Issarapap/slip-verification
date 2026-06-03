"use client"

import { PlusIcon, SearchIcon, XIcon } from "lucide-react"
import * as React from "react"
import { Button } from "../components/button"
import { Input } from "../components/input"
import { Popover, PopoverContent, PopoverTrigger } from "../components/popover"
import { Spinner } from "../components/spinner"
import { cn } from "../lib/utils"

const CHIP_ACTIVE_CLASS =
  "border-primary bg-primary/5 font-medium text-foreground hover:bg-primary/5"
const CHIP_INACTIVE_CLASS = "text-muted-foreground"

export interface AsyncSelectChipProps<T> {
  /** Label shown when no value is selected (e.g. "Merchant"). */
  label: string
  /** Currently selected ID, or null when nothing is picked. */
  value: string | null
  /** Pretty display label for the current value. Falls back to truncated value when absent. */
  valueLabel?: string
  /** Called when the user picks an item or clears the selection. */
  onChange: (value: string | null, item?: T) => void

  /** Search input value — caller controls this (typically a `useState` that feeds a debounce). */
  query: string
  /** Search input change handler. */
  onQueryChange: (query: string) => void

  /** Resolved options for the current debounced query. */
  options: T[]
  /** Loading state for the options query. */
  isLoading?: boolean

  /** Extract the option's ID. */
  getItemValue: (item: T) => string
  /** Render an option row's content (label + optional muted hint). */
  renderItem: (item: T) => React.ReactNode

  /** Placeholder for the search input. */
  placeholder?: string
  /** Message when the resolved-options array is empty but a query was typed. */
  emptyText?: string
  /** Helper text when the query is empty (e.g. "Type to search…"). */
  initialText?: string
  /** Label for the clear action shown at the popover footer when a value is selected. */
  clearLabel?: string

  /** Extra className on the trigger button. */
  className?: string
}

function truncateId(id: string): string {
  return id.length > 12 ? `${id.slice(0, 8)}…` : id
}

export function AsyncSelectChip<T>({
  label,
  value,
  valueLabel,
  onChange,
  query,
  onQueryChange,
  options,
  isLoading,
  getItemValue,
  renderItem,
  placeholder = "Search…",
  emptyText = "No results",
  initialText = "Type to search…",
  clearLabel = "Clear",
  className,
}: AsyncSelectChipProps<T>) {
  const [open, setOpen] = React.useState(false)
  const hasValue = value != null && value !== ""
  const inputRef = React.useRef<HTMLInputElement>(null)

  const displayLabel = hasValue ? `${label}: ${valueLabel ?? truncateId(value as string)}` : label

  // Focus the search input on open
  React.useEffect(() => {
    if (open) {
      const handle = window.setTimeout(() => inputRef.current?.focus(), 0)
      return () => window.clearTimeout(handle)
    }
  }, [open])

  const handleSelect = (item: T) => {
    onChange(getItemValue(item), item)
    setOpen(false)
    onQueryChange("")
  }

  const handleClear = () => {
    onChange(null)
    setOpen(false)
    onQueryChange("")
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          className={cn(hasValue ? CHIP_ACTIVE_CLASS : CHIP_INACTIVE_CLASS, className)}
        >
          {!hasValue && <PlusIcon className="size-3" />}
          {displayLabel}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-72 p-1">
        <div className="flex flex-col">
          {/* Search input */}
          <div className="relative px-1 pt-1 pb-2">
            <SearchIcon className="absolute left-3 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground pointer-events-none" />
            <Input
              ref={inputRef}
              type="text"
              value={query}
              onChange={(e) => onQueryChange(e.target.value)}
              placeholder={placeholder}
              className="h-8 pl-7 text-xs"
            />
            {query && (
              <Button
                type="button"
                variant="ghost"
                size="icon-xs"
                onClick={() => {
                  onQueryChange("")
                  inputRef.current?.focus()
                }}
                className="absolute right-1.5 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                aria-label="Clear search"
              >
                <XIcon className="size-3.5" />
              </Button>
            )}
          </div>

          {/* Results */}
          <div className="max-h-64 overflow-y-auto">
            {isLoading ? (
              <div className="flex items-center justify-center gap-2 px-2 py-4 text-xs text-muted-foreground">
                <Spinner className="size-3" />
                <span>Loading…</span>
              </div>
            ) : options.length === 0 ? (
              <div className="px-2 py-4 text-center text-xs text-muted-foreground">
                {query ? emptyText : initialText}
              </div>
            ) : (
              options.map((item) => {
                const itemValue = getItemValue(item)
                const isSelected = itemValue === value
                return (
                  <Button
                    key={itemValue}
                    type="button"
                    variant="ghost"
                    size="sm"
                    onClick={() => handleSelect(item)}
                    className={cn(
                      "h-auto w-full justify-start gap-2 rounded-sm px-2 py-1.5 font-normal",
                      isSelected && "font-medium text-primary"
                    )}
                  >
                    {renderItem(item)}
                  </Button>
                )
              })
            )}
          </div>

          {/* Clear footer */}
          {hasValue && (
            <>
              <div className="my-1 h-px bg-border" />
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={handleClear}
                className="h-auto w-full justify-start rounded-sm px-2 py-1.5 font-normal text-muted-foreground hover:text-foreground"
              >
                {clearLabel}
              </Button>
            </>
          )}
        </div>
      </PopoverContent>
    </Popover>
  )
}
