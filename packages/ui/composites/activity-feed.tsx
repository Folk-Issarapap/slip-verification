"use client"

import type { ReactNode } from "react"
import { cn } from "../lib/utils"

export type ActivityFeedTone = "success" | "info" | "warning" | "danger" | "neutral"

export type ActivityFeedItem = {
  id: string
  title: ReactNode
  description?: ReactNode
  actor?: ReactNode
  timestamp: ReactNode
  tone?: ActivityFeedTone
}

export type ActivityFeedProps = {
  items: ActivityFeedItem[]
  emptyState?: ReactNode
  className?: string
}

const TONE_CLASS: Record<ActivityFeedTone, string> = {
  success: "bg-success",
  info: "bg-info",
  warning: "bg-warning",
  danger: "bg-danger",
  neutral: "bg-muted-foreground/50",
}

export function ActivityFeed({ items, emptyState, className }: ActivityFeedProps) {
  if (items.length === 0) {
    return emptyState ? (
      emptyState
    ) : (
      <div className="flex items-center justify-center py-8 text-muted-foreground">
        No recent activity.
      </div>
    )
  }

  return (
    <ul className={cn("relative", className)}>
      {items.map((item, index) => (
        <li key={item.id} className="relative grid grid-cols-[16px_1fr] gap-3 py-2">
          {index < items.length - 1 ? (
            <span className="absolute top-[22px] bottom-[-8px] left-[7px] w-px bg-border" />
          ) : null}
          <span
            className={cn(
              "z-10 mt-1 size-3.5 rounded-full border-2 border-background",
              TONE_CLASS[item.tone ?? "neutral"]
            )}
          />
          <div className="min-w-0 space-y-0.5">
            <div className="font-medium">{item.title}</div>
            {item.description ? (
              <div className="font-mono text-xs text-muted-foreground">{item.description}</div>
            ) : null}
            <div className="font-mono text-xs text-muted-foreground">
              {[item.actor, item.timestamp].filter(Boolean).map((value, valueIndex) => (
                // biome-ignore lint/suspicious/noArrayIndexKey: stable two-part inline metadata
                <span key={valueIndex}>
                  {valueIndex > 0 ? " · " : null}
                  {value}
                </span>
              ))}
            </div>
          </div>
        </li>
      ))}
    </ul>
  )
}
