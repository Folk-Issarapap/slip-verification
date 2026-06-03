"use client"

import {
  type ChartConfig,
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
} from "@workspace/ui/components/chart"
import { Empty, EmptyHeader, EmptyMedia, EmptyTitle } from "@workspace/ui/components/empty"
import { Skeleton } from "@workspace/ui/components/skeleton"
import { satang, satangToThb } from "@workspace/ui/lib/money"
import { ArrowLeftRightIcon } from "lucide-react"
import { useMemo } from "react"
import { Bar, CartesianGrid, ComposedChart, Line, ReferenceLine, XAxis, YAxis } from "recharts"
import { Card } from "../components/card"

export type MerchantMoneyFlowDailyRow = {
  date: string
  payin: number
  deposit: number
  payout: number
  withdraw: number
}

export interface MerchantMoneyFlowChartLabels {
  payin: string
  deposit: string
  payout: string
  withdraw: string
  netCumulative: string
  empty: string
}

export interface MerchantMoneyFlowChartBucket {
  date: string
  payin: number
  deposit: number
  payout: number
  withdraw: number
  cumulativeNet: number
}

export function buildMerchantMoneyFlowChartBuckets(
  daily: MerchantMoneyFlowDailyRow[] | undefined
): MerchantMoneyFlowChartBucket[] {
  if (!daily?.length) return []
  let cumulative = 0
  return daily.map((d) => {
    const dailyNet = d.payin + d.deposit - d.payout - d.withdraw
    cumulative += dailyNet
    return {
      date: d.date,
      payin: d.payin,
      deposit: d.deposit,
      payout: -d.payout,
      withdraw: -d.withdraw,
      cumulativeNet: cumulative,
    }
  })
}

function formatCompactThb(satangValue: number): string {
  const thb = satangToThb(satang(Math.abs(satangValue)))
  const sign = satangValue < 0 ? "-" : ""
  if (thb >= 1_000_000) return `${sign}฿${(thb / 1_000_000).toFixed(1)}M`
  if (thb >= 1_000) return `${sign}฿${Math.round(thb / 1_000)}k`
  return `${sign}฿${Math.round(thb)}`
}

export interface MerchantMoneyFlowChartViewProps {
  daily: MerchantMoneyFlowDailyRow[] | undefined
  isLoading: boolean
  days: number
  labels: MerchantMoneyFlowChartLabels
  /** When true, wraps chart area in bordered card shell (merchant dashboard). When false, fills parent (admin CardContent). */
  embedded?: boolean
}

export function MerchantMoneyFlowChartView({
  daily,
  isLoading,
  days,
  labels,
  embedded = true,
}: MerchantMoneyFlowChartViewProps) {
  const chartData = useMemo(() => buildMerchantMoneyFlowChartBuckets(daily), [daily])

  const hasData = chartData.some(
    (d) => d.payin > 0 || d.deposit > 0 || d.payout < 0 || d.withdraw < 0
  )

  const config: ChartConfig = {
    payin: { label: labels.payin, color: "var(--success)" },
    deposit: { label: labels.deposit, color: "var(--info)" },
    payout: { label: labels.payout, color: "var(--warning)" },
    withdraw: { label: labels.withdraw, color: "var(--danger)" },
    cumulativeNet: { label: labels.netCumulative, color: "var(--foreground)" },
  }

  const inner = (
    <>
      {isLoading ? (
        <Skeleton className="h-56 w-full" />
      ) : !hasData ? (
        <Empty className="h-56 min-h-56 border-0 bg-transparent p-4">
          <EmptyHeader>
            <EmptyMedia variant="icon">
              <ArrowLeftRightIcon />
            </EmptyMedia>
            <EmptyTitle className="text-xs font-normal text-muted-foreground">
              {labels.empty}
            </EmptyTitle>
          </EmptyHeader>
        </Empty>
      ) : (
        <ChartContainer config={config} className="h-56 w-full min-w-0">
          <ComposedChart data={chartData} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
            <CartesianGrid vertical={false} strokeDasharray="3 3" className="stroke-border/40" />
            <XAxis
              dataKey="date"
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              tickFormatter={(value: string) => {
                const d = new Date(value)
                return `${d.getDate()}/${d.getMonth() + 1}`
              }}
              interval={days <= 7 ? 0 : days <= 30 ? 4 : 13}
              className="text-xs"
            />
            <YAxis
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              tickFormatter={(value: number) => formatCompactThb(value)}
              width={56}
              className="text-xs"
            />
            <ReferenceLine y={0} stroke="var(--border)" />
            <ChartTooltip
              cursor={false}
              content={
                <ChartTooltipContent
                  formatter={(value, name, item) => {
                    const formatted =
                      typeof value === "number"
                        ? new Intl.NumberFormat("th-TH", {
                            style: "currency",
                            currency: "THB",
                            minimumFractionDigits: 2,
                          }).format(satangToThb(satang(Math.abs(value))))
                        : String(value)
                    const label = config[name as keyof typeof config]?.label ?? name
                    const swatchColor =
                      (item as { color?: string; payload?: { fill?: string } } | undefined)
                        ?.color ??
                      (item as { color?: string; payload?: { fill?: string } } | undefined)?.payload
                        ?.fill
                    return (
                      <>
                        <span
                          aria-hidden
                          className="size-2.5 shrink-0 rounded-[2px]"
                          style={{ backgroundColor: swatchColor }}
                        />
                        <div className="flex flex-1 items-center justify-between gap-3 leading-none">
                          <span className="text-muted-foreground">{label}</span>
                          <span className="font-mono font-medium tabular-nums text-foreground">
                            {formatted}
                          </span>
                        </div>
                      </>
                    )
                  }}
                />
              }
            />
            <ChartLegend content={<ChartLegendContent />} />
            <Bar dataKey="payin" stackId="inflow" fill="var(--color-payin)" />
            <Bar dataKey="deposit" stackId="inflow" fill="var(--color-deposit)" />
            <Bar dataKey="payout" stackId="outflow" fill="var(--color-payout)" />
            <Bar dataKey="withdraw" stackId="outflow" fill="var(--color-withdraw)" />
            <Line
              type="monotone"
              dataKey="cumulativeNet"
              stroke="var(--color-cumulativeNet)"
              strokeWidth={1.5}
              dot={false}
              isAnimationActive={false}
            />
          </ComposedChart>
        </ChartContainer>
      )}
    </>
  )

  if (!embedded) {
    return inner
  }

  return <Card>{inner}</Card>
}
