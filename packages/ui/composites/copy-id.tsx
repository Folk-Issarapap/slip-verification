"use client"

import { Tooltip, TooltipContent, TooltipTrigger } from "@workspace/ui/components/tooltip"
import { CopyIconButton } from "./copy-icon-button"

interface CopyIdProps {
  id: string
  copyLabel: string
  className?: string
}

/**
 * Renders a truncated mono ID with a small copy icon button. For non-ID
 * values where you want the same affordance, compose your own
 * `<span>{display}</span> + <CopyIconButton/>`.
 */
export function CopyId({ id, copyLabel, className }: CopyIdProps) {
  const short = id.length > 12 ? `${id.slice(0, 8)}…${id.slice(-4)}` : id

  return (
    <div className={`flex items-center gap-1.5 ${className ?? ""}`}>
      <Tooltip>
        <TooltipTrigger asChild>
          <span className="font-mono text-xs text-muted-foreground cursor-default">{short}</span>
        </TooltipTrigger>
        <TooltipContent className="font-mono">{id}</TooltipContent>
      </Tooltip>
      <CopyIconButton value={id} ariaLabel={copyLabel} />
    </div>
  )
}
