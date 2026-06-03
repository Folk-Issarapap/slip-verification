"use client"

import type { ReactNode } from "react"
import { useEffect, useMemo, useState } from "react"
import { Button } from "../components/button"
import { Checkbox } from "../components/checkbox"
import { Label } from "../components/label"
import { RadioGroup, RadioGroupItem } from "../components/radio-group"
import { Separator } from "../components/separator"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "../components/sheet"
import { Spinner } from "../components/spinner"

export interface ExportColumnDef<TRow> {
  /** Stable key used to remember selection state. */
  key: string
  label: string
  /** Pull a printable value from a row. Strings are CSV-escaped automatically. */
  value: (row: TRow) => string | number | null | undefined
  defaultSelected?: boolean
}

export interface ExportScope {
  value: string
  label: string
  description?: string
}

export interface DataExportSheetLabels {
  scopeHeading: string
  columnsHeading: string
  cancel: string
  submit: string
  submitting?: string
  failure?: string
}

export interface DataExportSheetProps<TRow> {
  trigger: ReactNode
  title: string
  description?: string
  columns: ExportColumnDef<TRow>[]
  scopes: ExportScope[]
  defaultScope?: string
  fetchRows: (scope: string) => Promise<TRow[]>
  filename: (scope: string) => string
  labels: DataExportSheetLabels
  /** Called after a successful export. */
  onSuccess?: (info: { scope: string; rowCount: number }) => void
  onError?: (err: unknown) => void
}

export function DataExportSheet<TRow>({
  trigger,
  title,
  description,
  columns,
  scopes,
  defaultScope,
  fetchRows,
  filename,
  labels,
  onSuccess,
  onError,
}: DataExportSheetProps<TRow>) {
  const [open, setOpen] = useState(false)
  const [scope, setScope] = useState<string>(defaultScope ?? scopes[0]?.value ?? "")
  const [selected, setSelected] = useState<Record<string, boolean>>({})
  const [submitting, setSubmitting] = useState(false)

  // Initialize / reset selection when the sheet opens.
  useEffect(() => {
    if (!open) return
    setSelected(
      Object.fromEntries(columns.map((c) => [c.key, c.defaultSelected ?? true])) as Record<
        string,
        boolean
      >
    )
    setScope((current) => current || defaultScope || scopes[0]?.value || "")
  }, [open, columns, defaultScope, scopes])

  const selectedColumns = useMemo(() => columns.filter((c) => selected[c.key]), [columns, selected])

  const canExport = !submitting && selectedColumns.length > 0 && !!scope

  async function handleExport() {
    if (!canExport) return
    setSubmitting(true)
    try {
      const rows = await fetchRows(scope)
      const csv = toCsv(rows, selectedColumns)
      downloadCsv(csv, filename(scope))
      onSuccess?.({ scope, rowCount: rows.length })
      setOpen(false)
    } catch (err) {
      onError?.(err)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger asChild>{trigger}</SheetTrigger>
      <SheetContent className="flex flex-col gap-0 p-0">
        <SheetHeader className="border-b px-4 py-3">
          <SheetTitle>{title}</SheetTitle>
          {description ? <SheetDescription>{description}</SheetDescription> : null}
        </SheetHeader>

        <div className="flex-1 space-y-5 overflow-y-auto px-4 py-5">
          <section className="space-y-3">
            <Label className="text-xs font-medium text-muted-foreground">
              {labels.scopeHeading}
            </Label>
            <RadioGroup value={scope} onValueChange={setScope} className="gap-3">
              {scopes.map((s) => (
                <div key={s.value} className="flex items-start gap-2">
                  <RadioGroupItem
                    id={`export-scope-${s.value}`}
                    value={s.value}
                    className="mt-0.5"
                  />
                  <div className="space-y-0.5">
                    <Label htmlFor={`export-scope-${s.value}`} className="cursor-pointer">
                      {s.label}
                    </Label>
                    {s.description ? (
                      <p className="text-xs text-muted-foreground">{s.description}</p>
                    ) : null}
                  </div>
                </div>
              ))}
            </RadioGroup>
          </section>

          <Separator />

          <section className="space-y-3">
            <Label className="text-xs font-medium text-muted-foreground">
              {labels.columnsHeading}
            </Label>
            <div className="space-y-2">
              {columns.map((c) => (
                <div key={c.key} className="flex items-center gap-2">
                  <Checkbox
                    id={`export-col-${c.key}`}
                    checked={selected[c.key] ?? false}
                    onCheckedChange={(v) =>
                      setSelected((prev) => ({ ...prev, [c.key]: v === true }))
                    }
                  />
                  <Label htmlFor={`export-col-${c.key}`} className="cursor-pointer">
                    {c.label}
                  </Label>
                </div>
              ))}
            </div>
          </section>
        </div>

        <SheetFooter className="flex-row justify-end gap-2 border-t px-4 py-3">
          <Button variant="outline" onClick={() => setOpen(false)} disabled={submitting}>
            {labels.cancel}
          </Button>
          <Button onClick={handleExport} disabled={!canExport}>
            {submitting ? <Spinner data-icon="inline-start" /> : null}
            {submitting ? (labels.submitting ?? labels.submit) : labels.submit}
          </Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  )
}

export function toCsv<TRow>(rows: TRow[], cols: ExportColumnDef<TRow>[]): string {
  const header = cols.map((c) => csvEscape(c.label)).join(",")
  const body = rows.map((row) => cols.map((c) => csvEscape(c.value(row))).join(","))
  return [header, ...body].join("\n")
}

function csvEscape(value: unknown): string {
  if (value === null || value === undefined) return ""
  const str = typeof value === "string" ? value : String(value)
  if (str.includes(",") || str.includes('"') || str.includes("\n") || str.includes("\r")) {
    return `"${str.replace(/"/g, '""')}"`
  }
  return str
}

export function downloadCsv(csv: string, filename: string) {
  // BOM keeps Excel happy with UTF-8 + Thai characters.
  const blob = new Blob(["\ufeff", csv], { type: "text/csv;charset=utf-8" })
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}
