"use client"

import { AlertCircleIcon } from "lucide-react"
import type { ReactElement, ReactNode } from "react"
import { z } from "zod"
import { cn } from "../lib/utils"

const CommissionSchema = z.object({
  merchant_id: z.string(),
  merchant_name: z.string(),
  amount: z.number().int().nonnegative(),
})

const FeeCascadeMetadataSchema = z.object({
  fee_total: z.number().int().nonnegative(),
  platform_residual: z.number().int().nonnegative(),
  commissions: z.array(CommissionSchema),
})

export type FeeCascadeData = {
  fee_total: number
  platform_residual: number
  commissions: ReadonlyArray<{
    merchant_id: string
    merchant_name: string
    amount: number
  }>
  /** True when platform_residual + sum(commissions) equals fee_total (within 1 satang). */
  invariantOk: boolean
}

/**
 * Parses the JSON-encoded `metadata` field from a `fee_distributed` settlement
 * event. Returns `null` on null input, empty string, invalid JSON, or schema
 * failure.
 */
export function parseFeeCascadeMetadata(metadata: string | null): FeeCascadeData | null {
  if (!metadata || metadata.trim() === "") return null

  let raw: unknown
  try {
    raw = JSON.parse(metadata)
  } catch {
    return null
  }

  const result = FeeCascadeMetadataSchema.safeParse(raw)
  if (!result.success) return null

  const { fee_total, platform_residual, commissions } = result.data
  const commissionSum = commissions.reduce((acc, c) => acc + c.amount, 0)
  const invariantOk = Math.abs(platform_residual + commissionSum - fee_total) <= 1

  return { fee_total, platform_residual, commissions, invariantOk }
}

const COMMISSION_COLORS = [
  "bg-primary/70",
  "bg-primary/50",
  "bg-primary/35",
  "bg-primary/25",
] as const

function commissionColor(index: number): string {
  return COMMISSION_COLORS[index % COMMISSION_COLORS.length] ?? COMMISSION_COLORS[0]
}

export type FeeCascadeLabels = {
  platformLabel: string
  totalFee: string
  noCommissions: string
  invariantWarning: string
}

export function FeeCascadeBreakdown({
  data,
  labels,
  formatAmount,
  className,
}: {
  data: FeeCascadeData
  labels: FeeCascadeLabels
  formatAmount: (value: number) => ReactNode
  className?: string
}): ReactElement {
  const { fee_total, platform_residual, commissions, invariantOk } = data
  const safeTotal = fee_total === 0 ? 1 : fee_total

  function pct(amount: number): number {
    return (amount / safeTotal) * 100
  }

  return (
    <div className={cn(className)}>
      <div className="flex h-1.5 w-full overflow-hidden rounded-full">
        <div
          className={cn("h-full bg-primary", pct(platform_residual) < 1 && "min-w-[2px]")}
          style={{ flexBasis: `${pct(platform_residual)}%` }}
          title={labels.platformLabel}
        />
        {commissions.map((commission, index) => (
          <div
            key={commission.merchant_id}
            className={cn(
              "h-full",
              commissionColor(index),
              pct(commission.amount) < 1 && "min-w-[2px]"
            )}
            style={{ flexBasis: `${pct(commission.amount)}%` }}
            title={commission.merchant_name}
          />
        ))}
      </div>

      <ul className="mt-3 space-y-2">
        <li className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <span className="size-2 shrink-0 rounded-sm bg-primary" aria-hidden />
            <span>
              {labels.platformLabel}
              <span className="ml-1 text-muted-foreground">
                ({pct(platform_residual).toFixed(1)}%)
              </span>
            </span>
          </div>
          <span className="tabular-nums">{formatAmount(platform_residual)}</span>
        </li>

        {commissions.map((commission, index) => (
          <li key={commission.merchant_id} className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <span
                className={cn("size-2 shrink-0 rounded-sm", commissionColor(index))}
                aria-hidden
              />
              <span>
                {commission.merchant_name}
                <span className="ml-1 text-muted-foreground">
                  ({pct(commission.amount).toFixed(1)}%)
                </span>
              </span>
            </div>
            <span className="tabular-nums">{formatAmount(commission.amount)}</span>
          </li>
        ))}
      </ul>

      {commissions.length === 0 && (
        <p className="mt-2 text-muted-foreground">{labels.noCommissions}</p>
      )}

      <div className="mt-3 border-t border-border/60 pt-3">
        <div className="flex items-center justify-between gap-3">
          <span className="font-medium">{labels.totalFee}</span>
          <span className="font-medium tabular-nums">{formatAmount(fee_total)}</span>
        </div>
        {!invariantOk && (
          <p className="mt-1.5 text-warning">
            <AlertCircleIcon className="mr-1 inline-block size-3.5 align-text-bottom" />
            {labels.invariantWarning}
          </p>
        )}
      </div>
    </div>
  )
}
