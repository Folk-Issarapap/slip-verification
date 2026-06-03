"use client"

import { cn } from "@workspace/ui/lib/utils"

export function ReadField({
  label,
  value,
  mono,
}: {
  label: string
  value: React.ReactNode
  mono?: boolean
}) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={cn("mt-0.5 font-medium", mono && "font-mono")}>{value ?? "—"}</p>
    </div>
  )
}
