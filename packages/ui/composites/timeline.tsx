"use client"

import * as React from "react"

import { cn } from "../lib/utils"

// ── Context ───────────────────────────────────────────────────────────────────

type TimelineContextValue = {
  activeStep: number
  setActiveStep: (step: number) => void
}

const TimelineContext = React.createContext<TimelineContextValue | undefined>(undefined)

function useTimeline() {
  const ctx = React.useContext(TimelineContext)
  if (!ctx) throw new Error("useTimeline must be used within a Timeline")
  return ctx
}

// ── Timeline (root) ──────────────────────────────────────────────────────────

type TimelineProps = React.ComponentProps<"div"> & {
  defaultValue?: number
  value?: number
  onValueChange?: (value: number) => void
  orientation?: "horizontal" | "vertical"
}

function Timeline({
  defaultValue = 1,
  value,
  onValueChange,
  orientation = "vertical",
  className,
  children,
  ...props
}: TimelineProps) {
  const [internalStep, setInternalStep] = React.useState(defaultValue)

  const setActiveStep = React.useCallback(
    (step: number) => {
      if (value === undefined) setInternalStep(step)
      onValueChange?.(step)
    },
    [value, onValueChange]
  )

  const currentStep = value ?? internalStep

  return (
    <TimelineContext.Provider value={{ activeStep: currentStep, setActiveStep }}>
      <div
        data-slot="timeline"
        data-orientation={orientation}
        className={cn(
          "group/timeline flex data-[orientation=horizontal]:w-full data-[orientation=horizontal]:flex-row data-[orientation=vertical]:flex-col",
          className
        )}
        {...props}
      >
        {children}
      </div>
    </TimelineContext.Provider>
  )
}

// ── TimelineItem ─────────────────────────────────────────────────────────────

type TimelineItemProps = React.ComponentProps<"div"> & { step: number }

function TimelineItem({ step, className, children, ...props }: TimelineItemProps) {
  const { activeStep } = useTimeline()
  return (
    <div
      data-slot="timeline-item"
      data-completed={step <= activeStep || undefined}
      className={cn(
        "group/timeline-item relative flex flex-1 flex-col gap-0.5 group-data-[orientation=vertical]/timeline:ms-8 group-data-[orientation=horizontal]/timeline:mt-8 group-data-[orientation=horizontal]/timeline:not-last:pe-8 group-data-[orientation=vertical]/timeline:not-last:pb-6 has-[+[data-completed]]:**:data-[slot=timeline-separator]:bg-primary",
        className
      )}
      {...props}
    >
      {children}
    </div>
  )
}

// ── TimelineHeader ───────────────────────────────────────────────────────────

function TimelineHeader({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="timeline-header" className={cn(className)} {...props}>
      {children}
    </div>
  )
}

// ── TimelineDate ─────────────────────────────────────────────────────────────

function TimelineDate({ className, children, ...props }: React.ComponentProps<"time">) {
  return (
    <time
      data-slot="timeline-date"
      className={cn(
        "mb-1 block font-medium text-muted-foreground text-xs group-data-[orientation=vertical]/timeline:max-sm:h-4",
        className
      )}
      {...props}
    >
      {children}
    </time>
  )
}

// ── TimelineTitle ────────────────────────────────────────────────────────────

function TimelineTitle({ className, children, ...props }: React.ComponentProps<"h3">) {
  return (
    <h3 data-slot="timeline-title" className={cn("font-medium", className)} {...props}>
      {children}
    </h3>
  )
}

// ── TimelineContent ──────────────────────────────────────────────────────────

function TimelineContent({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="timeline-content" className={cn("text-muted-foreground", className)} {...props}>
      {children}
    </div>
  )
}

// ── TimelineIndicator ────────────────────────────────────────────────────────

function TimelineIndicator({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      aria-hidden
      data-slot="timeline-indicator"
      className={cn(
        "group-data-[orientation=horizontal]/timeline:-top-6 group-data-[orientation=horizontal]/timeline:-translate-y-1/2 group-data-[orientation=vertical]/timeline:-left-6 group-data-[orientation=vertical]/timeline:-translate-x-1/2 absolute size-4 rounded-full border-2 border-primary/20 group-data-[orientation=vertical]/timeline:top-0 group-data-[orientation=horizontal]/timeline:left-0 group-data-completed/timeline-item:border-primary",
        className
      )}
      {...props}
    >
      {children}
    </div>
  )
}

// ── TimelineSeparator ────────────────────────────────────────────────────────

function TimelineSeparator({ className, children, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      aria-hidden
      data-slot="timeline-separator"
      className={cn(
        "group-data-[orientation=horizontal]/timeline:-top-6 group-data-[orientation=horizontal]/timeline:-translate-y-1/2 group-data-[orientation=vertical]/timeline:-left-6 group-data-[orientation=vertical]/timeline:-translate-x-1/2 absolute self-start bg-primary/10 group-last/timeline-item:hidden group-data-[orientation=horizontal]/timeline:h-0.5 group-data-[orientation=vertical]/timeline:h-[calc(100%-1rem-0.25rem)] group-data-[orientation=horizontal]/timeline:w-[calc(100%-1rem-0.25rem)] group-data-[orientation=vertical]/timeline:w-0.5 group-data-[orientation=horizontal]/timeline:translate-x-4.5 group-data-[orientation=vertical]/timeline:translate-y-4.5",
        className
      )}
      {...props}
    >
      {children}
    </div>
  )
}

export {
  Timeline,
  TimelineContent,
  TimelineDate,
  TimelineHeader,
  TimelineIndicator,
  TimelineItem,
  TimelineSeparator,
  TimelineTitle,
}
