import * as React from "react"

import { cn } from "../lib/utils"

function Card({
  className,
  size = "default",
  variant = "sectioned",
  ...props
}: React.ComponentProps<"div"> & { size?: "default" | "sm"; variant?: "default" | "sectioned" }) {
  return (
    <div
      data-slot="card"
      data-size={size}
      data-variant={variant}
      className={cn(
        "group/card flex flex-col gap-4 overflow-hidden rounded-lg bg-card py-4 text-xs/relaxed text-card-foreground ring-1 ring-border/70 has-[>img:first-child]:pt-0 data-[size=sm]:gap-3 data-[size=sm]:py-3 data-[layout=data-grid]:gap-0 data-[layout=data-grid]:py-0 data-[layout=data-grid]:[&>[data-slot=card-footer]]:border-t data-[layout=data-grid]:[&>[data-slot=card-footer]]:bg-muted/20 data-[layout=data-grid]:[&>[data-slot=card-footer]]:py-3 data-[layout=data-grid]:[&>[data-slot=card-header]]:border-b data-[layout=data-grid]:[&>[data-slot=card-header]]:py-3 data-[layout=kpi-strip]:gap-0 data-[layout=kpi-strip]:py-0 data-[variant=sectioned]:gap-0 data-[variant=sectioned]:py-0 data-[variant=sectioned]:[&>[data-slot=card-content]]:py-4 data-[variant=sectioned]:[&>[data-slot=card-footer]]:border-t data-[variant=sectioned]:[&>[data-slot=card-footer]]:bg-muted/30 data-[variant=sectioned]:[&>[data-slot=card-footer]]:py-4 data-[variant=sectioned]:[&>[data-slot=card-header]]:border-b data-[variant=sectioned]:[&>[data-slot=card-header]]:py-3 *:[img:first-child]:rounded-t-lg *:[img:last-child]:rounded-b-lg",
        "data-[slot=page-hero]:bg-hero",
        className
      )}
      {...props}
    />
  )
}

function DataGridCard({ ...props }: Omit<React.ComponentProps<typeof Card>, "className">) {
  return <Card data-layout="data-grid" data-slot="data-grid-card" variant="default" {...props} />
}

function KpiStripCard({ ...props }: Omit<React.ComponentProps<typeof Card>, "className">) {
  return <Card data-layout="kpi-strip" data-slot="kpi-strip-card" variant="default" {...props} />
}

function CardHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-header"
      className={cn(
        "group/card-header @container/card-header grid auto-rows-min items-start gap-1.5 rounded-t-lg px-4 group-data-[size=sm]/card:px-3 has-data-[slot=card-action]:grid-cols-[1fr_auto] has-data-[slot=card-description]:grid-rows-[auto_auto] [.border-b]:pb-4 group-data-[size=sm]/card:[.border-b]:pb-3",
        className
      )}
      {...props}
    />
  )
}

function CardTitle({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-title"
      className={cn(
        "font-heading text-balance text-sm font-medium tracking-tight text-card-foreground",
        className
      )}
      {...props}
    />
  )
}

function CardDescription({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-description"
      className={cn("text-pretty text-xs/relaxed text-muted-foreground", className)}
      {...props}
    />
  )
}

function CardAction({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-action"
      className={cn(
        "col-start-2 row-span-2 row-start-1 flex items-center gap-2 self-start justify-self-end",
        className
      )}
      {...props}
    />
  )
}

function CardContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-content"
      className={cn("px-4 group-data-[size=sm]/card:px-3", className)}
      {...props}
    />
  )
}

function CardFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-footer"
      className={cn(
        "flex flex-wrap items-center gap-2 rounded-b-lg px-4 group-data-[size=sm]/card:px-3 [.border-t]:pt-4 group-data-[size=sm]/card:[.border-t]:pt-3",
        className
      )}
      {...props}
    />
  )
}

export {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
  DataGridCard,
  KpiStripCard,
}
