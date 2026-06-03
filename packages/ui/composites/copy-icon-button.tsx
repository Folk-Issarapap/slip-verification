"use client"

import { Button } from "@workspace/ui/components/button"
import { toast } from "@workspace/ui/components/sonner"
import { cn } from "@workspace/ui/lib/utils"
import { CheckIcon, CopyIcon } from "lucide-react"
import { useState } from "react"

interface CopyIconButtonProps {
  value: string
  /** aria-label + tooltip text — caller localises (e.g. "Copy ID"). */
  ariaLabel: string
  /** Toast text on successful copy. Pass null to suppress the toast. */
  copiedLabel?: string | null
  /** Optional className for the button. */
  className?: string
}

/**
 * Compact ghost icon button that copies `value` to the clipboard. Briefly
 * swaps the icon to a check on success. Use this when you want the
 * displayed text to stay non-button (CopyChip wraps the whole pill as a
 * button instead — pick that when the whole value should be clickable).
 */
export function CopyIconButton({
  value,
  ariaLabel,
  copiedLabel = "Copied to clipboard",
  className,
}: CopyIconButtonProps) {
  const [copied, setCopied] = useState(false)

  async function handleCopy(e: React.MouseEvent<HTMLButtonElement>) {
    // Don't trigger the parent row's onRowClick / onClick handlers when the
    // copy button lives inside a clickable cell.
    e.stopPropagation()
    try {
      await navigator.clipboard.writeText(value)
      setCopied(true)
      if (copiedLabel) toast.success(copiedLabel)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // clipboard API may be blocked — silent fail
    }
  }

  return (
    <Button
      type="button"
      size="icon-xs"
      variant="ghost"
      onClick={handleCopy}
      aria-label={ariaLabel}
      className={cn("size-6", className)}
    >
      {copied ? <CheckIcon className="size-3" /> : <CopyIcon className="size-3" />}
    </Button>
  )
}
