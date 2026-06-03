"use client"

import { Button } from "@workspace/ui/components/button"
import { toast } from "@workspace/ui/components/sonner"
import { cn } from "@workspace/ui/lib/utils"

type CopyChipProps = {
  value: string
  copiedLabel: string
  ariaLabel: string
  children?: React.ReactNode
  className?: string
}

export function CopyChip({ value, copiedLabel, ariaLabel, children, className }: CopyChipProps) {
  return (
    <Button
      variant="ghost"
      size="sm"
      type="button"
      aria-label={ariaLabel}
      className={cn(
        "h-auto -mx-1.5 px-1.5 py-0.5 rounded font-mono text-xs bg-muted hover:bg-muted/80",
        className
      )}
      onClick={() => {
        navigator.clipboard.writeText(value).then(() => toast.success(copiedLabel))
      }}
    >
      {children ?? value}
    </Button>
  )
}
