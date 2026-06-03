"use client"

import { ArrowLeft } from "lucide-react"
import * as React from "react"
import { Button } from "../components/button"
import { Card, CardContent } from "../components/card"
import { cn } from "../lib/utils"

// PageHero — richer, Card-based alternative to PageHeading. Use for detail
// pages where the entity has identity (avatar/icon), status (badges), and
// secondary meta. PageHeading remains the right choice for list/index pages.
//
// Slots compose through an inner flex layout + data-slot attrs:
//   row 1 ─ PageHeroBack (full width, when present)
//   row 2 ─ PageHeroMedia | PageHeroContent | PageHeroActions
// Any slot can be omitted; content flexes to occupy remaining width.
//
// PageHeroActions is intended for ONE primary lifecycle action (e.g. Suspend
// / Activate). Group secondary actions (reset password, revoke sessions) into
// a dedicated sidebar Card — see AccountSecurityCard for the canonical pattern.

// ── Root ─────────────────────────────────────────────────────────────────────

function PageHero({ className, children, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <Card data-slot="page-hero" variant="default" {...props}>
      <CardContent>
        <div
          data-slot="page-hero-layout"
          className={cn(
            "flex flex-col gap-4 sm:flex-row sm:flex-wrap sm:items-start",
            "[&>[data-slot=page-hero-actions]]:sm:ml-auto",
            "[&>[data-slot=page-hero-back]]:basis-full",
            "[&>[data-slot=page-hero-content]]:sm:flex-1",
            className
          )}
        >
          {children}
        </div>
      </CardContent>
    </Card>
  )
}

// ── Back link (col-span row above the media/content/actions row) ─────────────

interface PageHeroBackProps extends React.AnchorHTMLAttributes<HTMLAnchorElement> {
  icon?: React.ComponentType<{ className?: string }>
}

function PageHeroBack({
  className,
  icon: Icon = ArrowLeft,
  children,
  ...props
}: PageHeroBackProps) {
  return (
    <Button
      variant="outline"
      size="sm"
      asChild
      data-slot="page-hero-back"
      className={cn("w-fit", className)}
    >
      <a {...props}>
        <Icon />
        {children}
      </a>
    </Button>
  )
}

// ── Media slot (avatar / logo / icon) ────────────────────────────────────────

function PageHeroMedia({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-hero-media"
      className={cn("flex shrink-0 items-center", className)}
      {...props}
    />
  )
}

// ── Content column ───────────────────────────────────────────────────────────

function PageHeroContent({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-hero-content"
      className={cn("flex min-w-0 flex-1 flex-col gap-1", className)}
      {...props}
    />
  )
}

// ── Header row (title + inline badges) ───────────────────────────────────────

function PageHeroHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-hero-header"
      className={cn("flex flex-wrap items-center gap-2", className)}
      {...props}
    />
  )
}

// ── Title ────────────────────────────────────────────────────────────────────

interface PageHeroTitleProps extends React.HTMLAttributes<HTMLHeadingElement> {
  as?: "h1" | "h2" | "h3"
}

function PageHeroTitle({ as: Component = "h1", className, ...props }: PageHeroTitleProps) {
  return (
    <Component
      data-slot="page-hero-title"
      className={cn("font-heading text-xl font-semibold tracking-tight text-foreground", className)}
      {...props}
    />
  )
}

// ── Description (subtitle line under the title) ──────────────────────────────

function PageHeroDescription({ className, ...props }: React.HTMLAttributes<HTMLParagraphElement>) {
  return (
    <p
      data-slot="page-hero-description"
      className={cn("text-muted-foreground", className)}
      {...props}
    />
  )
}

// ── Meta row ─────────────────────────────────────────────────────────────────

function PageHeroMeta({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-hero-meta"
      className={cn("mt-1 flex flex-wrap items-center gap-x-4 gap-y-1", className)}
      {...props}
    />
  )
}

function PageHeroMetaItem({ className, ...props }: React.HTMLAttributes<HTMLSpanElement>) {
  return (
    <span
      data-slot="page-hero-meta-item"
      className={cn("inline-flex items-center gap-1.5 text-muted-foreground", className)}
      {...props}
    />
  )
}

// ── Actions ──────────────────────────────────────────────────────────────────

function PageHeroActions({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-slot="page-hero-actions"
      className={cn("flex shrink-0 flex-wrap items-center justify-end gap-2 self-start", className)}
      {...props}
    />
  )
}

// ── Exports ──────────────────────────────────────────────────────────────────

export {
  PageHero,
  PageHeroActions,
  PageHeroBack,
  PageHeroContent,
  PageHeroDescription,
  PageHeroHeader,
  PageHeroMedia,
  PageHeroMeta,
  PageHeroMetaItem,
  PageHeroTitle,
}
