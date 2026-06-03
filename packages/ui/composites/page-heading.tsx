"use client"

import { ArrowLeft } from "lucide-react"
import * as React from "react"
import { Button } from "../components/button"
import { cn } from "../lib/utils"

// ── Context ──────────────────────────────────────────────────────────────────

export type PageHeadingVariant = "default" | "sub"

const PageHeadingContext = React.createContext<{
  hasBack: boolean
  variant: PageHeadingVariant
}>({ hasBack: false, variant: "default" })

// ── Root ─────────────────────────────────────────────────────────────────────

type PageHeadingProps = React.HTMLAttributes<HTMLDivElement> & {
  variant?: PageHeadingVariant
}

function PageHeading({ className, children, variant = "default", ...props }: PageHeadingProps) {
  // Layout via CSS Grid:
  // - 2 columns: 1fr | auto
  // - Breadcrumb / Back take col-span-2 so they appear on their own row
  // - Content sits in col 1, Actions in col 2 of the next row
  // Runtime slot detection is impossible across RSC client-reference
  // boundaries (child.type is a lazy proxy, not the original function), so
  // we let CSS + data-slot do the work.
  return (
    <PageHeadingContext.Provider value={{ hasBack: true, variant }}>
      <div
        className={cn(
          "grid grid-cols-[minmax(0,1fr)_auto] items-start gap-x-4 gap-y-2",
          "[&>[data-slot=page-heading-breadcrumb]]:col-span-2",
          "[&>[data-slot=page-heading-back]]:col-span-2",
          className
        )}
        {...props}
      >
        {children}
      </div>
    </PageHeadingContext.Provider>
  )
}

// ── Breadcrumb slot ──────────────────────────────────────────────────────────

function PageHeadingBreadcrumb({ className, ...props }: React.HTMLAttributes<HTMLElement>) {
  return (
    <nav
      data-slot="page-heading-breadcrumb"
      aria-label="breadcrumb"
      className={cn(className)}
      {...props}
    />
  )
}
PageHeadingBreadcrumb.displayName = "PageHeadingBreadcrumb"

// ── Back button ──────────────────────────────────────────────────────────────

interface PageHeadingBackProps extends React.AnchorHTMLAttributes<HTMLAnchorElement> {
  icon?: React.ComponentType<{ className?: string }>
}

function PageHeadingBack({
  className,
  icon: Icon = ArrowLeft,
  children,
  ...props
}: PageHeadingBackProps) {
  return (
    <Button
      variant="outline"
      size="sm"
      asChild
      data-slot="page-heading-back"
      className={cn("w-fit", className)}
    >
      <a {...props}>
        <Icon />
        {children}
      </a>
    </Button>
  )
}
PageHeadingBack.displayName = "PageHeadingBack"

// ── Content wrapper ──────────────────────────────────────────────────────────

function PageHeadingContent({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-heading-content"
      className={cn("min-w-0 space-y-1", className)}
      {...props}
    />
  )
}

// ── Title ────────────────────────────────────────────────────────────────────

interface PageHeadingTitleProps extends React.HTMLAttributes<HTMLHeadingElement> {
  as?: "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
}

function PageHeadingTitle({ as: Component = "h1", className, ...props }: PageHeadingTitleProps) {
  const { variant } = React.useContext(PageHeadingContext)
  return (
    <Component
      className={cn(
        "font-heading tracking-tight text-foreground",
        variant === "default" && "text-xl font-semibold",
        variant === "sub" && "text-lg font-semibold",
        className
      )}
      {...props}
    />
  )
}

// ── Description ──────────────────────────────────────────────────────────────

function PageHeadingDescription({
  className,
  ...props
}: React.HTMLAttributes<HTMLParagraphElement>) {
  const { variant } = React.useContext(PageHeadingContext)
  return (
    <p
      className={cn(
        "text-muted-foreground",
        variant === "default" && "text-xs",
        variant === "sub" && "text-xs",
        className
      )}
      {...props}
    />
  )
}

// ── Actions ──────────────────────────────────────────────────────────────────

function PageHeadingActions({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-heading-actions"
      className={cn("flex shrink-0 items-center justify-end gap-2", className)}
      {...props}
    />
  )
}

// ── Meta row ─────────────────────────────────────────────────────────────────

function PageHeadingMeta({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cn("mt-1 flex flex-wrap items-center gap-x-4 gap-y-1", className)} {...props} />
  )
}

function PageHeadingMetaItem({ className, ...props }: React.HTMLAttributes<HTMLSpanElement>) {
  return (
    <span className={cn("flex items-center gap-1.5 text-muted-foreground", className)} {...props} />
  )
}

// ── Exports ──────────────────────────────────────────────────────────────────

export {
  PageHeading,
  PageHeadingActions,
  PageHeadingBack,
  PageHeadingBreadcrumb,
  PageHeadingContent,
  PageHeadingDescription,
  PageHeadingMeta,
  PageHeadingMetaItem,
  PageHeadingTitle,
}
