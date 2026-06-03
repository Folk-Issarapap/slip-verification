import { cn } from "@workspace/ui/lib/utils"
import type { ComponentProps, ReactNode } from "react"

// Omit "title" because the HTML attribute is `string | undefined`, but our
// prop accepts ReactNode. Without this, the interface fails to extend.
interface SectionHeadProps extends Omit<ComponentProps<"div">, "title"> {
  /** The heading text. Renders as <h3> by default. */
  title: ReactNode
  /** Inline subtitle / description / count meta. Muted, smaller. */
  subtitle?: ReactNode
  /** Trailing actions (links, buttons, badges) right-aligned. */
  actions?: ReactNode
  /** Heading level: 2 or 3. Default 3. */
  as?: "h2" | "h3"
}

export function SectionHead({
  title,
  subtitle,
  actions,
  as = "h3",
  className,
  ...props
}: SectionHeadProps) {
  const Heading = as
  // Without actions: simple inline title + subtitle row aligned on baseline.
  // With actions: justify-between with title block on the left, actions shrink-0 on the right.
  if (actions) {
    return (
      <div
        className={cn(
          "mb-3 flex flex-col items-stretch gap-2 sm:flex-row sm:items-center sm:justify-between sm:gap-3",
          className
        )}
        {...props}
      >
        <div className="min-w-0 space-y-1 sm:flex sm:items-baseline sm:gap-2 sm:space-y-0">
          <Heading className="font-medium sm:truncate">{title}</Heading>
          {subtitle && (
            <span className="block text-xs text-muted-foreground sm:truncate">{subtitle}</span>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-2 sm:justify-end">{actions}</div>
      </div>
    )
  }
  return (
    <div className={cn("mb-3 flex items-baseline gap-2", className)} {...props}>
      <Heading className="font-medium">{title}</Heading>
      {subtitle && <span className="text-xs text-muted-foreground">{subtitle}</span>}
    </div>
  )
}
