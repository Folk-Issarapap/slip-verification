"use client"

import {
  type ColumnDef,
  type ExpandedState,
  flexRender,
  getCoreRowModel,
  getExpandedRowModel,
  getPaginationRowModel,
  getSortedRowModel,
  type PaginationState,
  type Row,
  type RowSelectionState,
  type SortingState,
  useReactTable,
} from "@tanstack/react-table"
import { useVirtualizer } from "@tanstack/react-virtual"
import * as React from "react"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "../components/alert-dialog"
import { Button } from "../components/button"
import { Checkbox } from "../components/checkbox"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "../components/dropdown-menu"
import { NativeSelect, NativeSelectOption } from "../components/native-select"
import { Skeleton } from "../components/skeleton"
import { TableBody, TableCell, TableHead, TableHeader } from "../components/table"
import { cn } from "../lib/utils"

// ─── Types ───────────────────────────────────────────────────────────────────

export interface DataGridColumnDef<TData> {
  id: string
  header: string
  accessorKey: keyof TData & string
  align?: "left" | "center" | "right"
  width?: number
  mono?: boolean
  enableSorting?: boolean
  /** Pin column to left or right edge on horizontal scroll */
  sticky?: "left" | "right"
  /** Custom cell render */
  cell?: (value: unknown, row: TData) => React.ReactNode
}

export interface RowAction<TData> {
  label: string
  variant?: "default" | "destructive"
  onClick: (row: TData) => void
  /** Return true to hide this action for a specific row */
  hidden?: (row: TData) => boolean
}

export interface BulkAction {
  label: string
  variant?: "default" | "outline" | "destructive"
  onClick: (selectedIds: string[]) => void
  /**
   * Optional confirm dialog. When set, clicking the action opens an
   * AlertDialog instead of firing immediately. `onClick` runs only after
   * the user confirms.
   *
   * Required for any destructive bulk action (delete, freeze, suspend, etc).
   */
  confirm?: {
    /** Dialog title — e.g. "Delete {count} users?" — receives `{count}` placeholder */
    title: string
    /** Dialog description — receives `{count}` placeholder */
    description: string
    /** Confirm button label — e.g. "Delete" */
    actionLabel: string
    /** Cancel button label — defaults to "Cancel" */
    cancelLabel?: string
  }
}

export interface SortField {
  id: string
  desc: boolean
}

export interface PaginationMeta {
  page: number
  pageSize: number
  total: number
}

/** Serialized filter state — Record<columnId, selectedValues[]> */
export type FilterState = Record<string, string[]>

export interface DataGridProps<TData extends { id: string }> {
  data: TData[]
  columns: DataGridColumnDef<TData>[]
  rowActions?: RowAction<TData>[]
  bulkActions?: BulkAction[]
  onRowClick?: (row: TData) => void
  getRowId?: (row: TData) => string
  /** Enable virtual scrolling for large datasets */
  virtualScrollHeight?: number
  className?: string
  /** Pagination footer style. "default" = full row-count/page/nav controls. "compact" = "X-Y of Z · N across all pages" + page-number buttons only. */
  paginationVariant?: "default" | "compact"
  /** Server-side sorting — when provided, sorting is manual (no client-side sort) */
  onSortChange?: (sorting: SortField[]) => void
  /** Controlled sort state for server-side sorting */
  sorting?: SortField[]
  /** Enable pagination. Number = fixed page size. Default: off (all rows). */
  pageSize?: number
  /** Server-side pagination — when provided, pagination is manual */
  onPageChange?: (page: number, pageSize: number) => void
  /** Server-side pagination meta (required with onPageChange) */
  paginationMeta?: PaginationMeta
  /** Page size options shown in the selector (default: [10, 20, 50]) */
  pageSizeOptions?: number[]
  /** Show loading overlay on the table body */
  loading?: boolean
  /** Return sub-rows for expandable rows (e.g. product variants). Sub-rows render with same columns, indented. */
  getSubRows?: (row: TData) => TData[]
  /** Render custom expanded content below a row (full-width panel). Takes precedence over getSubRows. */
  renderExpandedRow?: (row: TData) => React.ReactNode
  /** Custom empty state rendered when there are no rows. The parent owns the "no data" vs "no results"
   *  distinction — compute it from search/filter state in the URL and pass the right ReactNode here. */
  emptyState?: React.ReactNode
  /** Control row selection per-row. Pass a function to disable selection for specific rows (e.g. current user). */
  enableRowSelection?: boolean | ((row: TData) => boolean)
  /** Visual mode. "default" = standalone with its own bordered table wrapper.
   *  "card" = nested inside a parent <Card>; suppresses the inner border/radius so the parent Card supplies them. */
  variant?: "default" | "card"
  /** Hide the footer row (row count / page-size selector). Use for embedded grids where the parent
   *  surface already shows the count (e.g. "5 of 14" beside the section title). */
  hideFooter?: boolean
  /** Expand the row inline when the row body is clicked. Only applies when `renderExpandedRow` is set. */
  expandOnRowClick?: boolean
  /** Localize the "N rows" footer label. Default: `(n) => \`${n} row${n !== 1 ? "s" : ""}\``. */
  rowCountLabel?: (count: number) => string
}

// ─── Status Cell Helper ─────────────────────────────────────────────────────

export function StatusCell({
  value,
  options,
}: {
  value: string
  options: { label: string; value: string; color?: string }[]
}) {
  const opt = options.find((o) => o.value === value)
  return (
    <div className="flex items-center gap-2">
      {opt?.color && <span className={cn("size-2 rounded-full", opt.color)} />}
      <span className="text-xs">{opt?.label ?? value}</span>
    </div>
  )
}

const skeletonRowKeys = ["sk-0", "sk-1", "sk-2", "sk-3", "sk-4"]

// ─── DataGrid ───────────────────────────────────────────────────────────────

export function DataGrid<TData extends { id: string }>({
  data,
  columns: gridColumns,
  rowActions,
  bulkActions,
  onRowClick,
  getRowId,
  virtualScrollHeight,
  className,
  paginationVariant = "default",
  onSortChange,
  sorting: controlledSorting,
  pageSize: pageSizeProp,
  onPageChange,
  paginationMeta,
  pageSizeOptions = [10, 20, 50],
  loading = false,
  getSubRows,
  renderExpandedRow,
  emptyState,
  enableRowSelection = true,
  variant = "default",
  hideFooter = false,
  expandOnRowClick = false,
  rowCountLabel = (n) => `${n} row${n !== 1 ? "s" : ""}`,
}: DataGridProps<TData>) {
  // ── Expandable rows ──
  const isExpandable = !!getSubRows || !!renderExpandedRow
  const [expanded, setExpanded] = React.useState<ExpandedState>({})

  // ── Server-side mode detection ──
  const isManualSort = !!onSortChange
  const isManualPagination = !!onPageChange
  const isPaginated = !!pageSizeProp

  // ── Sorting ──
  const [internalSorting, setInternalSorting] = React.useState<SortingState>([])

  const sorting: SortingState =
    controlledSorting && controlledSorting.length > 0
      ? controlledSorting.map((s) => ({ id: s.id, desc: s.desc }))
      : internalSorting

  // ── Pagination ──
  const [pagination, setPagination] = React.useState<PaginationState>({
    pageIndex: paginationMeta ? paginationMeta.page - 1 : 0,
    pageSize: pageSizeProp ?? 20,
  })

  // Sync internal pagination with external paginationMeta (server-side mode)
  React.useEffect(() => {
    if (paginationMeta) {
      setPagination((prev) => {
        const nextIndex = paginationMeta.page - 1
        const nextSize = paginationMeta.pageSize
        if (prev.pageIndex === nextIndex && prev.pageSize === nextSize) return prev
        return { pageIndex: nextIndex, pageSize: nextSize }
      })
    }
  }, [paginationMeta])

  // Reset page to first when sort changes (for both client & server)
  const resetPage = React.useCallback(() => {
    setPagination((prev) => (prev.pageIndex === 0 ? prev : { ...prev, pageIndex: 0 }))
  }, [])

  const onPageChangeRef = React.useRef(onPageChange)
  onPageChangeRef.current = onPageChange

  const handlePaginationChange = React.useCallback(
    (updaterOrValue: PaginationState | ((prev: PaginationState) => PaginationState)) => {
      setPagination((prev) => {
        const next = typeof updaterOrValue === "function" ? updaterOrValue(prev) : updaterOrValue
        if (isManualPagination) {
          onPageChangeRef.current?.(next.pageIndex + 1, next.pageSize)
        }
        return next
      })
    },
    [isManualPagination]
  )

  const handleSortingChange = React.useCallback(
    (updaterOrValue: SortingState | ((prev: SortingState) => SortingState)) => {
      const next = typeof updaterOrValue === "function" ? updaterOrValue(sorting) : updaterOrValue
      if (isManualSort) {
        onSortChange(next.map((s) => ({ id: s.id, desc: s.desc })))
      } else {
        setInternalSorting(next)
      }
      resetPage()
    },
    [sorting, isManualSort, onSortChange, resetPage]
  )

  // ── Row Selection ──
  const [rowSelection, setRowSelection] = React.useState<RowSelectionState>({})

  const tableContainerRef = React.useRef<HTMLDivElement>(null)

  // Build TanStack columns
  const hasSticky = gridColumns.some((c) => c.sticky)
  const tanstackColumns = React.useMemo<ColumnDef<TData>[]>(() => {
    const cols: ColumnDef<TData>[] = []

    // Expand toggle column
    if (isExpandable) {
      cols.push({
        id: "expand",
        meta: { sticky: hasSticky ? "left" : undefined },
        header: () => null,
        cell: ({ row }) => {
          if (!row.getCanExpand()) return null
          return (
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              className="text-muted-foreground hover:text-foreground"
              onClick={(e) => {
                e.stopPropagation()
                row.toggleExpanded()
              }}
            >
              <ChevronRightIcon
                className={cn("size-3.5 transition-transform", row.getIsExpanded() && "rotate-90")}
              />
            </Button>
          )
        },
        size: 32,
        enableSorting: false,
      })
    }

    // Selection column — only rendered when row selection is enabled.
    if (enableRowSelection !== false) {
      cols.push({
        id: "select",
        meta: { sticky: hasSticky ? "left" : undefined },
        header: ({ table }) => (
          <Checkbox
            checked={table.getIsAllPageRowsSelected()}
            onCheckedChange={(v) => table.toggleAllPageRowsSelected(!!v)}
          />
        ),
        cell: ({ row }) => (
          <Checkbox
            checked={row.getIsSelected()}
            onCheckedChange={(v) => row.toggleSelected(!!v)}
            onClick={(e) => e.stopPropagation()}
          />
        ),
        size: 40,
        enableSorting: false,
      })
    }

    for (const col of gridColumns) {
      cols.push({
        id: col.id,
        accessorKey: col.accessorKey,
        meta: { sticky: col.sticky, align: col.align },
        header: () => (
          <span
            className={cn(
              col.align === "right" && "block text-right",
              col.align === "center" && "block text-center"
            )}
          >
            {col.header}
          </span>
        ),
        cell: (info) => {
          const val = info.getValue()
          const row = info.row.original as TData

          if (col.cell) return col.cell(val, row)

          return (
            <span
              className={cn(
                col.mono && "font-mono tabular-nums",
                col.align === "right" && "block text-right",
                col.align === "center" && "block text-center"
              )}
            >
              {typeof val === "number" ? val.toLocaleString() : String(val ?? "")}
            </span>
          )
        },
        size: col.width,
        enableSorting: col.enableSorting !== false,
      })
    }

    // Row actions column — auto-sticks right if any column has sticky
    if (rowActions && rowActions.length > 0) {
      cols.push({
        id: "actions",
        meta: { sticky: hasSticky ? "right" : undefined },
        header: () => null,
        cell: ({ row }) => {
          const rowData = row.original as TData
          const visibleActions = rowActions.filter((a) => !a.hidden?.(rowData))
          if (visibleActions.length === 0) return null

          const stopProp = (e: React.SyntheticEvent) => e.stopPropagation()
          return (
            // biome-ignore lint/a11y/noStaticElementInteractions: stop-propagation wrapper for row click
            <div className="flex justify-end" onClick={stopProp} onKeyDown={stopProp}>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button
                    type="button"
                    variant="outline"
                    size="icon"
                    className="text-muted-foreground hover:text-foreground"
                  >
                    <MoreVerticalIcon />
                    <span className="sr-only">Actions</span>
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-40">
                  {visibleActions.map((action, i) => {
                    const prev = visibleActions[i - 1]
                    const showSep = prev && !prev.variant && action.variant === "destructive"
                    return (
                      <React.Fragment key={action.label}>
                        {showSep && <DropdownMenuSeparator />}
                        <DropdownMenuItem
                          variant={action.variant === "destructive" ? "destructive" : undefined}
                          onClick={() => action.onClick(rowData)}
                        >
                          {action.label}
                        </DropdownMenuItem>
                      </React.Fragment>
                    )
                  })}
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          )
        },
        size: 48,
        enableSorting: false,
      })
    }

    return cols
  }, [gridColumns, rowActions, isExpandable, hasSticky, enableRowSelection])

  // Compute sticky column offsets (cumulative left/right positions)
  const stickyOffsets = React.useMemo(() => {
    if (!hasSticky) return new Map<string, { side: "left" | "right"; offset: number }>()
    const map = new Map<string, { side: "left" | "right"; offset: number }>()

    // Left sticky — accumulate from left
    let leftOffset = 0
    for (const col of tanstackColumns) {
      const side = (col.meta as { sticky?: string })?.sticky
      if (side === "left") {
        map.set(col.id ?? "", { side: "left", offset: leftOffset })
        leftOffset += col.size ?? 100
      }
    }

    // Right sticky — accumulate from right
    let rightOffset = 0
    for (let i = tanstackColumns.length - 1; i >= 0; i--) {
      const col = tanstackColumns[i]
      if (!col) continue
      const side = (col.meta as { sticky?: string })?.sticky
      if (side === "right") {
        map.set(col.id ?? "", { side: "right", offset: rightOffset })
        rightOffset += col.size ?? 100
      }
    }

    return map
  }, [tanstackColumns, hasSticky])

  const table = useReactTable<TData>({
    data,
    columns: tanstackColumns,
    state: {
      sorting,
      rowSelection,
      ...(isPaginated ? { pagination } : {}),
      ...(isExpandable ? { expanded } : {}),
    },
    onSortingChange: handleSortingChange,
    onRowSelectionChange: setRowSelection,
    ...(isPaginated ? { onPaginationChange: handlePaginationChange } : {}),
    getCoreRowModel: getCoreRowModel(),
    ...(isManualSort ? { manualSorting: true } : { getSortedRowModel: getSortedRowModel() }),
    ...(isPaginated && !isManualPagination
      ? { getPaginationRowModel: getPaginationRowModel() }
      : {}),
    ...(isManualPagination
      ? {
          manualPagination: true,
          pageCount: paginationMeta ? Math.ceil(paginationMeta.total / pagination.pageSize) : -1,
        }
      : {}),
    getRowId: getRowId ?? ((row) => (row as TData).id),
    enableRowSelection:
      typeof enableRowSelection === "function"
        ? (row: Row<TData>) => (enableRowSelection as (row: TData) => boolean)(row.original)
        : enableRowSelection,
    ...(isExpandable
      ? {
          onExpandedChange: setExpanded,
          getExpandedRowModel: getExpandedRowModel(),
          getSubRows:
            getSubRows && !renderExpandedRow
              ? (row) => {
                  const subs = getSubRows(row as TData)
                  return subs && subs.length > 0 ? subs : undefined
                }
              : undefined,
          // For renderExpandedRow mode, every row can expand (no sub-rows needed)
          ...(renderExpandedRow ? { getRowCanExpand: () => true } : {}),
        }
      : {}),
  })

  const { rows } = table.getRowModel()

  // Virtual scrolling
  const rowVirtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => tableContainerRef.current,
    estimateSize: () => 49,
    overscan: 10,
    enabled: !!virtualScrollHeight,
  })

  const selectedCount = Object.keys(rowSelection).length
  const selectedIds = Object.keys(rowSelection)

  const displayRows = virtualScrollHeight
    ? rowVirtualizer.getVirtualItems()
    : rows.map((_, i) => ({ index: i, start: 0, size: 49, key: i }))

  return (
    <div className={cn("min-w-0 space-y-0", className)}>
      {/* Table */}
      <div
        ref={tableContainerRef}
        className={cn(
          "relative min-w-0 max-w-full overflow-x-auto overflow-y-auto overscroll-x-contain",
          variant === "default" && "rounded-lg border"
        )}
        style={virtualScrollHeight ? { maxHeight: virtualScrollHeight } : undefined}
      >
        {loading && <LoadingBar />}
        {/* biome-ignore lint/correctness/useUniqueElementIds: raw <table> element is intentional — the parent div is the virtualizer's scroll container; <Table> primitive's own wrapper would nest scroll contexts and break sticky thead */}
        <table className="w-full text-xs">
          <TableHeader className="sticky top-0 z-10">
            {table.getHeaderGroups().map((headerGroup) => (
              <tr
                key={headerGroup.id}
                className={cn("border-b", variant === "card" ? "bg-muted" : "bg-muted/50")}
              >
                {headerGroup.headers.map((header) => {
                  const sticky = stickyOffsets.get(header.column.id)
                  const align = (header.column.columnDef.meta as { align?: string } | undefined)
                    ?.align
                  return (
                    <TableHead
                      key={header.id}
                      className={cn(
                        "h-auto px-3 py-2 font-medium text-muted-foreground",
                        header.column.getCanSort() &&
                          "cursor-pointer select-none hover:text-foreground",
                        sticky && "sticky z-20",
                        sticky && (variant === "card" ? "bg-muted" : "bg-muted/50")
                      )}
                      style={{
                        ...(header.column.columnDef.size
                          ? { width: header.column.columnDef.size }
                          : {}),
                        ...(sticky ? { [sticky.side]: sticky.offset, position: "sticky" } : {}),
                      }}
                      onClick={header.column.getToggleSortingHandler()}
                    >
                      <span
                        className={cn(
                          "flex w-full items-center gap-1",
                          align === "right" && "justify-end text-right",
                          align === "center" && "justify-center text-center"
                        )}
                      >
                        {flexRender(header.column.columnDef.header, header.getContext())}
                        {{
                          asc: " ↑",
                          desc: " ↓",
                        }[header.column.getIsSorted() as string] ?? null}
                      </span>
                    </TableHead>
                  )
                })}
              </tr>
            ))}
          </TableHeader>
          <TableBody
            style={virtualScrollHeight ? { height: rowVirtualizer.getTotalSize() } : undefined}
            className={cn(
              "relative transition-opacity duration-150",
              loading && "opacity-50 pointer-events-none"
            )}
          >
            {displayRows.map((virtualRow) => {
              const row = rows[virtualRow.index]
              if (!row) return null
              const depth = row.depth ?? 0
              const isSubRow = depth > 0
              return (
                <React.Fragment key={row.id}>
                  <tr
                    data-state={row.getIsSelected() ? "selected" : undefined}
                    className={cn(
                      "border-b last:border-0 transition-colors hover:bg-muted/30",
                      row.getIsSelected() && "bg-primary/5",
                      isSubRow && "bg-muted/20",
                      (expandOnRowClick || onRowClick) && "cursor-pointer"
                    )}
                    style={
                      virtualScrollHeight
                        ? {
                            position: "absolute",
                            top: 0,
                            transform: `translateY(${virtualRow.start}px)`,
                            width: "100%",
                            display: "table-row",
                          }
                        : undefined
                    }
                    onClick={(e) => {
                      if ((e.target as HTMLElement).closest("[data-suppress-row-click]")) return
                      if (expandOnRowClick && renderExpandedRow) {
                        row.toggleExpanded()
                      }
                      onRowClick?.(row.original as TData)
                    }}
                  >
                    {row.getVisibleCells().map((cell, cellIndex) => {
                      // Indent the first content cell for sub-rows (skip expand + select columns)
                      const isFirstContentCell = isExpandable ? cellIndex === 2 : cellIndex === 1
                      const sticky = stickyOffsets.get(cell.column.id)
                      const align = (cell.column.columnDef.meta as { align?: string } | undefined)
                        ?.align
                      return (
                        <TableCell
                          key={cell.id}
                          className={cn(
                            "px-3 py-2.5",
                            align === "right" && "text-right",
                            align === "center" && "text-center",
                            isSubRow && isFirstContentCell && "pl-6",
                            sticky && "sticky z-10 bg-background",
                            sticky && row.getIsSelected() && "bg-primary/5",
                            sticky && isSubRow && "bg-muted/20"
                          )}
                          style={{
                            ...(cell.column.columnDef.size
                              ? { width: cell.column.columnDef.size }
                              : {}),
                            ...(sticky ? { [sticky.side]: sticky.offset, position: "sticky" } : {}),
                          }}
                        >
                          {flexRender(cell.column.columnDef.cell, cell.getContext())}
                        </TableCell>
                      )
                    })}
                  </tr>
                  {/* Expanded content panel (renderExpandedRow mode) */}
                  {renderExpandedRow && row.getIsExpanded() && (
                    <tr className="border-b bg-muted/10">
                      <TableCell colSpan={tanstackColumns.length} className="px-3 py-3">
                        {renderExpandedRow(row.original as TData)}
                      </TableCell>
                    </tr>
                  )}
                </React.Fragment>
              )
            })}
            {displayRows.length === 0 &&
              loading &&
              skeletonRowKeys.map((key) => (
                <tr key={key} className="border-b last:border-0">
                  {tanstackColumns.map((col) => (
                    <TableCell key={col.id} className="px-3 py-2.5">
                      <Skeleton className="h-4 w-3/4" />
                    </TableCell>
                  ))}
                </tr>
              ))}
            {displayRows.length === 0 && !loading && (
              <tr>
                <TableCell
                  colSpan={tanstackColumns.length}
                  className="px-3 py-8 text-center text-muted-foreground"
                >
                  {emptyState ?? "No data."}
                </TableCell>
              </tr>
            )}
          </TableBody>
        </table>
      </div>

      {/* Footer — row count + pagination */}
      {hideFooter ? null : paginationVariant === "compact" && isPaginated ? (
        (() => {
          const pageCount =
            isManualPagination && paginationMeta
              ? Math.ceil(paginationMeta.total / pagination.pageSize)
              : table.getPageCount()
          const currentPage = pagination.pageIndex + 1
          const pageRowCount =
            isManualPagination && paginationMeta
              ? Math.min(
                  paginationMeta.pageSize,
                  paginationMeta.total - (paginationMeta.page - 1) * paginationMeta.pageSize
                )
              : rows.length
          const startRow =
            isManualPagination && paginationMeta
              ? (paginationMeta.page - 1) * paginationMeta.pageSize + 1
              : pagination.pageIndex * pagination.pageSize + 1
          const endRow =
            isManualPagination && paginationMeta
              ? Math.min(paginationMeta.page * paginationMeta.pageSize, paginationMeta.total)
              : Math.min((pagination.pageIndex + 1) * pagination.pageSize, data.length)
          const totalRows =
            isManualPagination && paginationMeta ? paginationMeta.total : data.length

          if (pageRowCount === 0) return null

          // Build page-button list: all pages if ≤5, else first 3 + ellipsis + last
          const pageButtons: (number | "…")[] = []
          if (pageCount <= 5) {
            for (let p = 1; p <= pageCount; p++) pageButtons.push(p)
          } else {
            const near = new Set(
              [1, currentPage - 1, currentPage, currentPage + 1, pageCount].filter(
                (p) => p >= 1 && p <= pageCount
              )
            )
            let prev: number | null = null
            for (const p of Array.from(near).sort((a, b) => a - b)) {
              if (prev !== null && p - prev > 1) pageButtons.push("…")
              pageButtons.push(p)
              prev = p
            }
          }

          return (
            <div className="flex items-center justify-between border-t border-border bg-muted px-3 py-2 text-xs text-muted-foreground">
              <span className="tabular-nums">
                {startRow}–{endRow} of {pageRowCount} · {totalRows.toLocaleString()} across all
                pages
              </span>
              <div className="flex items-center gap-1">
                {pageButtons.map((p, i) =>
                  p === "…" ? (
                    <span
                      // biome-ignore lint/suspicious/noArrayIndexKey: ellipses have no stable id; position is the identity
                      key={`ellipsis-${i}`}
                      className="grid size-6 place-items-center text-xs text-muted-foreground"
                    >
                      …
                    </span>
                  ) : (
                    <Button
                      key={p}
                      type="button"
                      variant={p === currentPage ? "secondary" : "outline"}
                      size="icon-sm"
                      onClick={() =>
                        handlePaginationChange({ ...pagination, pageIndex: (p as number) - 1 })
                      }
                      className="font-mono"
                    >
                      {p}
                    </Button>
                  )
                )}
              </div>
            </div>
          )
        })()
      ) : (
        <div className="mt-2 flex min-w-0 flex-col gap-2 sm:flex-row sm:items-center sm:justify-between sm:gap-0">
          <div className="min-w-0 text-xs text-muted-foreground">
            {isPaginated ? (
              <>
                {isManualPagination && paginationMeta
                  ? `${(paginationMeta.page - 1) * paginationMeta.pageSize + 1}–${Math.min(paginationMeta.page * paginationMeta.pageSize, paginationMeta.total)} of ${paginationMeta.total.toLocaleString()}`
                  : `${pagination.pageIndex * pagination.pageSize + 1}–${Math.min((pagination.pageIndex + 1) * pagination.pageSize, data.length)} of ${data.length.toLocaleString()}`}
              </>
            ) : (
              <>{rowCountLabel(rows.length)}</>
            )}
          </div>

          {isPaginated && (
            <div className="flex min-w-0 flex-wrap items-center justify-end gap-2 sm:justify-end">
              {/* Page size selector */}
              <div className="flex shrink-0 items-center gap-1.5">
                <span className="text-xs text-muted-foreground">Rows</span>
                <NativeSelect
                  value={pagination.pageSize}
                  onChange={(e) => {
                    const newSize = Number(e.target.value)
                    handlePaginationChange({ pageIndex: 0, pageSize: newSize })
                  }}
                >
                  {Array.from(new Set([...pageSizeOptions, pagination.pageSize]))
                    .sort((a, b) => a - b)
                    .map((size) => (
                      <NativeSelectOption key={size} value={size}>
                        {size}
                      </NativeSelectOption>
                    ))}
                </NativeSelect>
              </div>

              <div className="mx-1 h-4 w-px bg-border" />

              {/* Page info */}
              <span className="text-xs text-muted-foreground tabular-nums">
                Page {pagination.pageIndex + 1} of{" "}
                {isManualPagination && paginationMeta
                  ? Math.ceil(paginationMeta.total / pagination.pageSize)
                  : table.getPageCount()}
              </span>

              {/* Navigation */}
              <div className="flex items-center gap-0.5">
                <Button
                  type="button"
                  variant="outline"
                  size="icon"
                  onClick={() => handlePaginationChange({ ...pagination, pageIndex: 0 })}
                  disabled={pagination.pageIndex === 0}
                >
                  <ChevronsLeftIcon />
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="icon"
                  onClick={() =>
                    handlePaginationChange({ ...pagination, pageIndex: pagination.pageIndex - 1 })
                  }
                  disabled={pagination.pageIndex === 0}
                >
                  <ChevronLeftIcon />
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="icon"
                  onClick={() =>
                    handlePaginationChange({ ...pagination, pageIndex: pagination.pageIndex + 1 })
                  }
                  disabled={
                    isManualPagination
                      ? paginationMeta
                        ? pagination.pageIndex >=
                          Math.ceil(paginationMeta.total / pagination.pageSize) - 1
                        : false
                      : !table.getCanNextPage()
                  }
                >
                  <ChevronRightSmIcon />
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="icon"
                  onClick={() => {
                    const lastPage =
                      isManualPagination && paginationMeta
                        ? Math.ceil(paginationMeta.total / pagination.pageSize) - 1
                        : table.getPageCount() - 1
                    handlePaginationChange({ ...pagination, pageIndex: lastPage })
                  }}
                  disabled={
                    isManualPagination
                      ? paginationMeta
                        ? pagination.pageIndex >=
                          Math.ceil(paginationMeta.total / pagination.pageSize) - 1
                        : false
                      : !table.getCanNextPage()
                  }
                >
                  <ChevronsRightIcon />
                </Button>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Bulk Actions Bar */}
      {selectedCount > 0 && bulkActions && bulkActions.length > 0 && (
        <div className="fixed inset-x-0 bottom-4 z-50 mx-auto flex w-fit items-center gap-3 rounded-lg border bg-background px-4 py-3 shadow-lg">
          <Checkbox checked onCheckedChange={() => setRowSelection({})} />
          <span className="font-medium">{selectedCount} selected</span>
          <div className="mx-1 h-5 w-px bg-border" />
          {bulkActions.map((action) => {
            const buttonVariant = action.variant === "destructive" ? "destructive" : "outline"

            if (action.confirm) {
              const fillCount = (s: string) => s.replace(/\{count\}/g, String(selectedCount))
              return (
                <AlertDialog key={action.label}>
                  <AlertDialogTrigger asChild>
                    <Button type="button" variant={buttonVariant} size="lg">
                      {action.label}
                    </Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>{fillCount(action.confirm.title)}</AlertDialogTitle>
                      <AlertDialogDescription>
                        {fillCount(action.confirm.description)}
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>
                        {action.confirm.cancelLabel ?? "Cancel"}
                      </AlertDialogCancel>
                      <AlertDialogAction
                        variant={action.variant === "destructive" ? "destructive" : "default"}
                        onClick={() => action.onClick(selectedIds)}
                      >
                        {action.confirm.actionLabel}
                      </AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              )
            }

            return (
              <Button
                key={action.label}
                type="button"
                variant={buttonVariant}
                size="lg"
                onClick={() => action.onClick(selectedIds)}
              >
                {action.label}
              </Button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ─── Loading Bar ────────────────────────────────────────────────────────────

const loadingKeyframeId = "datagrid-loading-keyframe"
function ensureLoadingKeyframe() {
  if (typeof document === "undefined") return
  if (document.getElementById(loadingKeyframeId)) return
  const style = document.createElement("style")
  style.id = loadingKeyframeId
  style.textContent = `@keyframes datagrid-loading { from { transform: translateX(0%); } to { transform: translateX(200%); } }`
  document.head.appendChild(style)
}

function LoadingBar() {
  React.useEffect(() => {
    ensureLoadingKeyframe()
  }, [])
  return (
    <div className="absolute inset-x-0 top-0 z-20 h-0.5 overflow-hidden bg-primary/10">
      <div
        className="h-full w-1/3 bg-primary/50 rounded-full"
        style={{ animation: "datagrid-loading 1s ease-in-out infinite alternate" }}
      />
    </div>
  )
}

// ─── Inline SVG icons ───────────────────────────────────────────────────────

function ChevronRightIcon({ className }: { className?: string }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      aria-hidden="true"
    >
      <path
        d="M5.25 3.5L8.75 7L5.25 10.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function MoreVerticalIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <circle cx="8" cy="4" r="1.25" fill="currentColor" />
      <circle cx="8" cy="8" r="1.25" fill="currentColor" />
      <circle cx="8" cy="12" r="1.25" fill="currentColor" />
    </svg>
  )
}

function ChevronsLeftIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <path
        d="M7 3.5L3.5 7L7 10.5M10.5 3.5L7 7L10.5 10.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function ChevronLeftIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <path
        d="M8.75 3.5L5.25 7L8.75 10.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function ChevronRightSmIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <path
        d="M5.25 3.5L8.75 7L5.25 10.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function ChevronsRightIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <path
        d="M3.5 3.5L7 7L3.5 10.5M7 3.5L10.5 7L7 10.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}
