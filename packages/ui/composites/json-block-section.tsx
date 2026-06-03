"use client"

import { CopyIcon } from "lucide-react"
import type { ReactNode } from "react"
import { toast } from "sonner"
import { Button } from "../components/button"
import { Card, CardContent } from "../components/card"
import { SectionHead } from "./section-head"

export function formatJsonBlock(raw: string): string {
  try {
    return JSON.stringify(JSON.parse(raw), null, 2)
  } catch {
    return raw
  }
}

export const JSON_BLOCK_PRE_CLASS =
  "max-h-80 overflow-auto font-mono text-xs leading-relaxed whitespace-pre-wrap break-all text-foreground"

export type JsonBlockSectionProps = {
  title: ReactNode
  value?: string | null
  /** Render section with an em-dash when value is missing. */
  alwaysShow?: boolean
  copy?: {
    label: string
    copiedMessage: string
  }
}

export function JsonBlockSection({
  title,
  value,
  alwaysShow = false,
  copy,
}: JsonBlockSectionProps) {
  const hasValue = value != null && value !== ""
  if (!hasValue && !alwaysShow) return null

  const pretty = hasValue ? formatJsonBlock(value) : null

  return (
    <section>
      <SectionHead
        title={title}
        actions={
          copy && hasValue ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                navigator.clipboard.writeText(value ?? "")
                toast.success(copy.copiedMessage)
              }}
            >
              <CopyIcon data-icon="inline-start" />
              {copy.label}
            </Button>
          ) : undefined
        }
      />
      <Card>
        <CardContent>
          {pretty ? <pre>{pretty}</pre> : <p className="text-muted-foreground">—</p>}
        </CardContent>
      </Card>
    </section>
  )
}
