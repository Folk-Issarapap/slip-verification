"use client"

import { cn } from "@workspace/ui/lib/utils"
import { TrendingDownIcon, TrendingUpIcon } from "lucide-react"

// ── Sparkline ─────────────────────────────────────────────────────────────────

export function Sparkline({
  data,
  color,
}: {
  data: number[]
  // Pass a CSS variable string (e.g. "var(--success)") so colors stay tokenized.
  color: string
}) {
  const width = 110
  const height = 28
  const padding = 1
  const min = Math.min(...data)
  const max = Math.max(...data)
  const range = max - min || 1
  const points = data
    .map((val, i) => {
      const x = padding + (i / (data.length - 1)) * (width - padding * 2)
      const y = height - padding - ((val - min) / range) * (height - padding * 2)
      return `${x},${y}`
    })
    .join(" ")
  const firstPoint = `${padding},${height - padding}`
  const lastPoint = `${width - padding},${height - padding}`
  const areaPoints = `${firstPoint} ${points} ${lastPoint}`
  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="block h-7 w-full max-w-[110px]"
      aria-hidden="true"
    >
      <polygon points={areaPoints} fill={color} fillOpacity={0.16} />
      <polyline
        points={points}
        fill="none"
        stroke={color}
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

// ── KpiTile ───────────────────────────────────────────────────────────────────

export interface KpiTileProps {
  label: string
  children: React.ReactNode // the big value (AppCurrency or count)
  change?: string
  changeType?: "positive" | "negative" | "neutral"
  sparklineData?: number[]
  // CSS variable string (e.g. "var(--success)"). Defaults to a sensible per-direction color.
  sparkColor?: string
}

export function KpiTile({
  label,
  children,
  change,
  changeType = "neutral",
  sparklineData,
  sparkColor,
}: KpiTileProps) {
  const resolvedSparkColor =
    sparkColor ??
    (changeType === "positive"
      ? "var(--success)"
      : changeType === "negative"
        ? "var(--danger)"
        : "var(--muted-foreground)")
  return (
    <div className="min-w-0 px-5 py-4">
      <p className="text-xs font-medium leading-none text-muted-foreground">{label}</p>
      <div className="mt-3 text-2xl font-semibold tracking-tight tabular-nums leading-none">
        {children}
      </div>
      <div className="mt-3 flex min-w-0 items-center gap-3 overflow-hidden">
        {change ? (
          <p
            className={cn(
              "min-w-0 shrink inline-flex items-center gap-1 font-mono text-xs font-medium leading-none tabular-nums",
              changeType === "positive" && "text-success",
              changeType === "negative" && "text-danger",
              changeType === "neutral" && "text-muted-foreground"
            )}
          >
            {changeType === "negative" ? (
              <TrendingDownIcon className="size-3 shrink-0" aria-hidden />
            ) : (
              <TrendingUpIcon className="size-3 shrink-0" aria-hidden />
            )}
            {change}
          </p>
        ) : null}
        {sparklineData && sparklineData.length > 1 ? (
          <div className="ms-auto min-w-0 max-w-full overflow-hidden">
            <Sparkline data={sparklineData} color={resolvedSparkColor} />
          </div>
        ) : null}
      </div>
    </div>
  )
}
