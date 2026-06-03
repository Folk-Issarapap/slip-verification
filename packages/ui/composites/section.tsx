import { cn } from "../lib/utils"

/**
 * SectionList — applies the "section recipe" hairline to direct-child
 * `<Section>`s (or any element). Every child after the first gets:
 *
 *   border-top: 1px solid var(--border);
 *   padding-top: 14px;
 *   margin-top: 14px;
 *
 * The first child skips all three. The reference spec calls for `margin-top:
 * 6px` (asymmetric), but with form-field sections above the hairline that's
 * too tight — the input's bottom border visually touches the hairline. Using
 * symmetric 14px above + below keeps the hairline centered between sections.
 */
function SectionList({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="section-list"
      className={cn(
        "[&>*:not(:first-child)]:mt-5 [&>*:not(:first-child)]:border-t [&>*:not(:first-child)]:border-border [&>*:not(:first-child)]:pt-5",
        className
      )}
      {...props}
    >
      {children}
    </div>
  )
}

function Section({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="section" className={cn(className)} {...props}>
      {children}
    </div>
  )
}

function SectionTitle({ className, children, ...props }: React.ComponentProps<"p">) {
  return (
    <p
      data-slot="section-title"
      className={cn("mb-4 font-semibold text-foreground", className)}
      {...props}
    >
      {children}
    </p>
  )
}

function SectionDescription({ className, children, ...props }: React.ComponentProps<"p">) {
  return (
    <p
      data-slot="section-description"
      className={cn("text-muted-foreground", className)}
      {...props}
    >
      {children}
    </p>
  )
}

function SectionContent({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="section-content" className={cn(className)} {...props}>
      {children}
    </div>
  )
}

export { Section, SectionContent, SectionDescription, SectionList, SectionTitle }
