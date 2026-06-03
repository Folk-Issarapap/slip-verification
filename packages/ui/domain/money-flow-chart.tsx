"use client"

import { Bar, CartesianGrid, ComposedChart, Line, ReferenceLine, XAxis, YAxis } from "recharts"
import {
  type ChartConfig,
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
} from "../components/chart"
import { satang, satangToThb } from "../lib/money"

export type MoneyFlowSeries = {
  key: string
  label: string
  type: "bar" | "line"
  color: string
  yAxisId?: "left" | "right"
}

interface MoneyFlowChartProps<T extends object> {
  data: T[]
  xAxisKey: string
  series: MoneyFlowSeries[]
  xAxisTickFormatter?: (value: string) => string
  yAxisTickFormatter?: (value: number) => string
  tooltipLabelFormatter?: (value: string | number) => string
  tooltipValueFormatter?: (value: number | string) => string
  xAxisInterval?: number
  showRightYAxis?: boolean
  showLegend?: boolean
  showZeroLine?: boolean
  className?: string
  height?: string
}

export function formatCompactThb(satangValue: number): string {
  const thb = satangToThb(satang(satangValue))
  if (thb >= 1_000_000) return `฿${(thb / 1_000_000).toFixed(1)}M`
  if (thb >= 1_000) return `฿${Math.round(thb / 1_000)}k`
  return `฿${Math.round(thb)}`
}

function formatThb(value: number | string): string {
  if (typeof value !== "number") return String(value)
  return new Intl.NumberFormat("th-TH", {
    style: "currency",
    currency: "THB",
    minimumFractionDigits: 2,
  }).format(satangToThb(satang(value)))
}

export function MoneyFlowChart<T extends object>({
  data,
  xAxisKey,
  series,
  xAxisTickFormatter,
  yAxisTickFormatter = formatCompactThb,
  tooltipLabelFormatter,
  tooltipValueFormatter = formatThb,
  xAxisInterval,
  showRightYAxis,
  showLegend = false,
  showZeroLine = false,
  className = "w-full min-w-0",
  height = "h-48",
}: MoneyFlowChartProps<T>) {
  const hasRightAxis = showRightYAxis ?? series.some((s) => s.yAxisId === "right")

  const config: ChartConfig = Object.fromEntries(
    series.map((s) => [s.key, { label: s.label, color: s.color }])
  )

  return (
    <div className={className}>
      <ChartContainer config={config} className={`${height} w-full min-w-0`}>
        <ComposedChart data={data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
          <CartesianGrid vertical={false} strokeDasharray="3 3" className="stroke-border/40" />
          <XAxis
            dataKey={xAxisKey}
            tickLine={false}
            axisLine={false}
            tickMargin={8}
            interval={xAxisInterval}
            tickFormatter={xAxisTickFormatter}
            className="text-xs"
          />
          <YAxis
            yAxisId="left"
            tickLine={false}
            axisLine={false}
            tickMargin={8}
            tickFormatter={yAxisTickFormatter}
            width={48}
            className="text-xs"
          />
          {hasRightAxis && (
            <YAxis
              yAxisId="right"
              orientation="right"
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              tickFormatter={yAxisTickFormatter}
              width={48}
              className="text-xs"
            />
          )}
          {showLegend && <ChartLegend content={<ChartLegendContent />} />}
          {showZeroLine && <ReferenceLine y={0} stroke="var(--border)" />}
          <ChartTooltip
            cursor={false}
            content={
              <ChartTooltipContent
                labelFormatter={
                  tooltipLabelFormatter
                    ? (value) => tooltipLabelFormatter(value as string | number)
                    : undefined
                }
                formatter={(value, name, item) => {
                  const label = config[name as string]?.label ?? name
                  const swatch =
                    (item as { color?: string; payload?: { fill?: string } } | undefined)?.color ??
                    (item as { color?: string; payload?: { fill?: string } } | undefined)?.payload
                      ?.fill
                  return (
                    <>
                      <span
                        aria-hidden
                        className="size-2.5 shrink-0 rounded-[2px]"
                        style={{ backgroundColor: swatch }}
                      />
                      <div className="flex flex-1 items-center justify-between gap-3 leading-none">
                        <span className="text-muted-foreground">{label}</span>
                        <span className="font-mono font-medium tabular-nums text-foreground">
                          {tooltipValueFormatter(value as number | string)}
                        </span>
                      </div>
                    </>
                  )
                }}
              />
            }
          />
          {series.map((s) =>
            s.type === "bar" ? (
              <Bar
                key={s.key}
                yAxisId={s.yAxisId ?? "left"}
                dataKey={s.key}
                fill={`var(--color-${s.key})`}
                radius={[2, 2, 0, 0]}
              />
            ) : (
              <Line
                key={s.key}
                yAxisId={s.yAxisId ?? "left"}
                dataKey={s.key}
                stroke={`var(--color-${s.key})`}
                dot={false}
                strokeWidth={1.5}
              />
            )
          )}
        </ComposedChart>
      </ChartContainer>
    </div>
  )
}
