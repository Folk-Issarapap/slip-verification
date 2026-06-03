"use client"

import { InfoIcon } from "lucide-react"
import type { ReactNode } from "react"
import { Badge } from "../components/badge"
import { Card, CardAction, CardContent, CardHeader, CardTitle } from "../components/card"
import { Separator } from "../components/separator"
import { Skeleton } from "../components/skeleton"
import { Tooltip, TooltipContent, TooltipTrigger } from "../components/tooltip"

// Source layers that can resolve a fee. Order mirrors precedence:
// integration > wallet > merchant > platform.
export type FeeSource = "integration" | "merchant" | "platform" | "wallet"

const FEE_SOURCE_VARIANT: Record<FeeSource, "success" | "info" | "warning"> = {
  integration: "success",
  merchant: "info",
  platform: "warning",
  wallet: "success",
}

export function FeeSourceBadge({ source, label }: { source: FeeSource; label: string }) {
  return <Badge variant={FEE_SOURCE_VARIANT[source]}>{label}</Badge>
}

export interface EffectiveFeeRow {
  source: FeeSource
  fee_percentage: number
  flat_fee_amount: number
  min_fee: number | null
  max_fee: number | null
  updated_at?: string | null
  created_at?: string | null
}

export interface FeeStreamRowLabels {
  rate: string
  flat: string
  min: string
  max: string
  lastUpdated?: string
}

export interface FeeStreamRowProps {
  streamLabel: string
  badge: ReactNode
  data: EffectiveFeeRow | null | undefined
  isLoading?: boolean
  labels: FeeStreamRowLabels
  formatRate: (pct: number) => string
  formatAmount: (satang: number) => ReactNode
  /**
   * Optional formatter for the "Last updated" timestamp footer.
   * When omitted the footer is never rendered, even if timestamps are present.
   */
  formatTimestamp?: (iso: string) => ReactNode
  /** Optional action slot (override/reset buttons) rendered below the dl. */
  action?: ReactNode
}

export function FeeStreamRow({
  streamLabel,
  badge,
  data,
  isLoading,
  labels,
  formatRate,
  formatAmount,
  formatTimestamp,
  action,
}: FeeStreamRowProps) {
  if (isLoading) {
    return <Skeleton className="h-24 w-full" />
  }
  if (!data) return null

  const isModified =
    formatTimestamp != null &&
    data.updated_at != null &&
    data.created_at != null &&
    Date.parse(data.updated_at) - Date.parse(data.created_at) > 5000

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs font-medium text-muted-foreground">{streamLabel}</span>
        {badge}
      </div>

      <dl className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-xs">
        <dt className="text-muted-foreground">{labels.rate}</dt>
        <dd className="font-mono text-right">{formatRate(data.fee_percentage)}</dd>

        <dt className="text-muted-foreground">{labels.flat}</dt>
        <dd className="font-mono text-right">{formatAmount(data.flat_fee_amount)}</dd>

        <dt className="text-muted-foreground">{labels.min}</dt>
        <dd className="font-mono text-right">
          {data.min_fee !== null ? formatAmount(data.min_fee) : "—"}
        </dd>

        <dt className="text-muted-foreground">{labels.max}</dt>
        <dd className="font-mono text-right">
          {data.max_fee !== null ? formatAmount(data.max_fee) : "—"}
        </dd>
      </dl>

      {isModified && labels.lastUpdated ? (
        <p className="text-xs text-muted-foreground">
          {labels.lastUpdated} · {formatTimestamp(data.updated_at as string)}
        </p>
      ) : null}

      {action ? <div className="pt-1">{action}</div> : null}
    </div>
  )
}

export interface EffectiveFeeCardShellProps {
  title: string
  titleHint?: string
  inbound: ReactNode
  outbound: ReactNode
}

export function EffectiveFeeCardShell({
  title,
  titleHint,
  inbound,
  outbound,
}: EffectiveFeeCardShellProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        {titleHint ? (
          <CardAction>
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  className="inline-flex items-center justify-center text-muted-foreground hover:text-foreground"
                  aria-label={titleHint}
                >
                  <InfoIcon className="size-3.5" />
                </button>
              </TooltipTrigger>
              <TooltipContent>{titleHint}</TooltipContent>
            </Tooltip>
          </CardAction>
        ) : null}
      </CardHeader>
      <CardContent>
        <div className="space-y-4">
          {inbound}
          <Separator />
          {outbound}
        </div>
      </CardContent>
    </Card>
  )
}
