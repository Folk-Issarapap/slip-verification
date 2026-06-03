"use client"

import type { ComponentProps, ReactNode } from "react"
import { Badge } from "../components/badge"
import { cn } from "../lib/utils"
import {
  Timeline,
  TimelineContent,
  TimelineDate,
  TimelineHeader,
  TimelineIndicator,
  TimelineItem,
  TimelineSeparator,
  TimelineTitle,
} from "./timeline"

export type LifecycleTone = "success" | "info" | "warning" | "danger" | "neutral"
export type LifecycleState = "complete" | "current" | "pending"

type BadgeVariant = ComponentProps<typeof Badge>["variant"]
type BadgeSize = ComponentProps<typeof Badge>["size"]

export type LifecycleTimelineItem = {
  id: string
  title: ReactNode
  description?: ReactNode
  timestamp: ReactNode
  status?: ReactNode
  statusVariant?: BadgeVariant
  statusSize?: BadgeSize
  meta?: ReactNode
  tone?: LifecycleTone
  state?: LifecycleState
}

export type LifecycleTimelineProps = {
  items: LifecycleTimelineItem[]
  className?: string
}

const STATE_CLASS: Record<LifecycleState, string> = {
  complete: "border-primary/45 bg-primary/20 text-primary",
  current: "border-primary/55 bg-card text-primary",
  pending: "border-muted-foreground/30 bg-card text-transparent",
}

export function LifecycleTimeline({ items, className }: LifecycleTimelineProps) {
  return (
    <Timeline value={items.length} className={className}>
      {items.map((item, index) => {
        const state = item.state ?? "complete"

        return (
          <TimelineItem key={item.id} step={index + 1}>
            <TimelineHeader>
              <TimelineDate>{item.timestamp}</TimelineDate>
              <TimelineTitle>
                <span className="inline-flex flex-wrap items-center gap-2">
                  <span>{item.title}</span>
                  {item.status ? (
                    <Badge variant={item.statusVariant ?? "neutral"} size={item.statusSize}>
                      {item.status}
                    </Badge>
                  ) : null}
                  {item.meta ? (
                    <span className="font-normal text-muted-foreground">{item.meta}</span>
                  ) : null}
                </span>
              </TimelineTitle>
            </TimelineHeader>
            <TimelineIndicator
              className={cn("size-3.5 border flex items-center justify-center", STATE_CLASS[state])}
            >
              {state === "complete" ? (
                <svg
                  aria-hidden="true"
                  className="size-2.5"
                  fill="none"
                  viewBox="0 0 16 16"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    d="m3.5 8.25 3 3 6-6.5"
                    stroke="currentColor"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth="2"
                  />
                </svg>
              ) : null}
            </TimelineIndicator>
            <TimelineSeparator className="w-px translate-y-4 bg-muted-foreground/20" />
            {item.description ? <TimelineContent>{item.description}</TimelineContent> : null}
          </TimelineItem>
        )
      })}
    </Timeline>
  )
}
