import { cn } from "@workspace/ui/lib/utils"
import type { ComponentProps, ReactNode } from "react"

export function DescriptionList({ className, ...props }: ComponentProps<"dl">) {
  return (
    <dl
      className={cn("grid grid-cols-[5rem_minmax(0,1fr)] gap-x-3 gap-y-2 text-xs", className)}
      {...props}
    />
  )
}

interface DescriptionItemProps {
  label: ReactNode
  children: ReactNode
  /** Apply a subtle tone color to the value. */
  tone?: "danger" | "success" | "warning" | "info"
  /** Bold the value (used for totals / hero rows). */
  emphasized?: boolean
  /** Truncate overflow with ellipsis. */
  truncate?: boolean
  /** Use mono font for the value (IDs, hashes, codes). */
  mono?: boolean
  /** Tabular numerals — pair with mono on numeric values. */
  tabular?: boolean
  /** Extra classes on the <dd>. */
  ddClassName?: string
  /** Extra classes on the <dt> (e.g. `truncate` for long single-word labels). */
  dtClassName?: string
}

export function DescriptionItem({
  label,
  children,
  tone,
  emphasized,
  truncate,
  mono,
  tabular,
  ddClassName,
  dtClassName,
}: DescriptionItemProps) {
  return (
    <>
      <dt className={cn("text-muted-foreground", dtClassName)}>{label}</dt>
      <dd
        className={cn(
          mono && "font-mono",
          tabular && "tabular-nums",
          emphasized && "font-medium",
          truncate && "truncate",
          tone === "danger" && "text-danger",
          tone === "success" && "text-success",
          tone === "warning" && "text-warning",
          tone === "info" && "text-info",
          ddClassName
        )}
      >
        {children}
      </dd>
    </>
  )
}
