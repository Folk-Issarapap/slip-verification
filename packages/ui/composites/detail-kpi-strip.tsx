"use client"

import { KpiStripCard } from "@workspace/ui/components/card"
import type { ReactNode } from "react"
import { KpiTile } from "./kpi-tile"

export type KpiTileConfig = {
  label: string
  value: ReactNode
  change?: string
  changeType?: "positive" | "negative" | "neutral"
  sparklineData?: number[]
  sparkColor?: string
}

export function DetailKpiStrip({
  tiles,
  columns = 4,
}: {
  tiles: KpiTileConfig[]
  columns?: 3 | 4 | 5 | 6
}) {
  const colClass = {
    3: "sm:grid-cols-3",
    4: "sm:grid-cols-4",
    5: "sm:grid-cols-5",
    6: "sm:grid-cols-6",
  }[columns]

  return (
    <KpiStripCard>
      <div
        className={`grid grid-cols-1 divide-y divide-border overflow-hidden ${colClass} sm:divide-x sm:divide-y-0`}
      >
        {tiles.map((tile) => (
          <KpiTile
            key={tile.label}
            label={tile.label}
            change={tile.change}
            changeType={tile.changeType}
            sparklineData={tile.sparklineData}
            sparkColor={tile.sparkColor}
          >
            {tile.value}
          </KpiTile>
        ))}
      </div>
    </KpiStripCard>
  )
}
