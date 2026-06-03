"use client"

import type { ReactNode } from "react"
import { Badge } from "../components/badge"
import { Card, CardContent, CardHeader, CardTitle } from "../components/card"
import { Separator } from "../components/separator"
import { Skeleton } from "../components/skeleton"

// Source layers that can resolve a per-transaction limit. Order mirrors
// precedence: integration > wallet > merchant > platform.
export type LimitSource = "integration" | "merchant" | "wallet" | "platform"

const LIMIT_SOURCE_VARIANT: Record<LimitSource, "success" | "info" | "warning" | "neutral"> = {
  integration: "success",
  merchant: "info",
  wallet: "warning",
  platform: "neutral",
}

export function LimitSourceBadge({ source, label }: { source: LimitSource; label: string }) {
  return <Badge variant={LIMIT_SOURCE_VARIANT[source]}>{label}</Badge>
}

export interface EffectiveLimitsRow {
  source: LimitSource
  min: number
  max: number
  updated_at?: string | null
  created_at?: string | null
}

export interface LimitFlowRowLabels {
  min: string
  max: string
  lastUpdated?: string
}

export interface LimitFlowRowProps {
  flowLabel: string
  badge: ReactNode
  entry: EffectiveLimitsRow | null | undefined
  isLoading?: boolean
  labels: LimitFlowRowLabels
  formatAmount: (satang: number) => ReactNode
  /**
   * Optional formatter for the "Last updated" timestamp footer.
   * When omitted the footer is never rendered, even if timestamps are present.
   */
  formatTimestamp?: (iso: string) => ReactNode
  /** Optional action slot (override/reset buttons) rendered below the dl. */
  action?: ReactNode
}

export function LimitFlowRow({
  flowLabel,
  badge,
  entry,
  isLoading,
  labels,
  formatAmount,
  formatTimestamp,
  action,
}: LimitFlowRowProps) {
  if (isLoading) {
    return <Skeleton className="h-24 w-full" />
  }
  if (!entry) return null

  const isModified =
    formatTimestamp != null &&
    entry.updated_at != null &&
    entry.created_at != null &&
    Date.parse(entry.updated_at) - Date.parse(entry.created_at) > 5000

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs font-medium text-muted-foreground">{flowLabel}</span>
        {badge}
      </div>

      <dl className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-xs">
        <dt className="text-muted-foreground">{labels.min}</dt>
        <dd className="font-mono text-right">{formatAmount(entry.min)}</dd>
        <dt className="text-muted-foreground">{labels.max}</dt>
        <dd className="font-mono text-right">{formatAmount(entry.max)}</dd>
      </dl>

      {isModified && labels.lastUpdated ? (
        <p className="text-xs text-muted-foreground">
          {labels.lastUpdated} · {formatTimestamp(entry.updated_at as string)}
        </p>
      ) : null}

      {action ? <div className="pt-1">{action}</div> : null}
    </div>
  )
}

export interface EffectiveLimitsCardShellProps {
  title: string
  payment: ReactNode
  payout: ReactNode
}

export function EffectiveLimitsCardShell({
  title,
  payment,
  payout,
}: EffectiveLimitsCardShellProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="space-y-4">
          {payment}
          <Separator />
          {payout}
        </div>
      </CardContent>
    </Card>
  )
}
