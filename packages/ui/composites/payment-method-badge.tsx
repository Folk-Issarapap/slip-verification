import { Badge, type badgeVariants } from "@workspace/ui/components/badge"
import { cn } from "@workspace/ui/lib/utils"
import type { VariantProps } from "class-variance-authority"
import { BanknoteIcon, QrCodeIcon } from "lucide-react"

type PaymentMethod = "promptpay" | "bank_transfer" | (string & {})

type BadgeVariant = VariantProps<typeof badgeVariants>["variant"]
type BadgeSize = VariantProps<typeof badgeVariants>["size"]

interface MethodConfig {
  variant: BadgeVariant
  Icon: React.ComponentType<{ className?: string }>
}

const METHOD_CONFIG: Record<string, MethodConfig> = {
  promptpay: { variant: "info", Icon: QrCodeIcon },
  bank_transfer: { variant: "neutral", Icon: BanknoteIcon },
}

interface PaymentMethodBadgeProps {
  method: PaymentMethod | null | undefined
  /** Optional override for the visible label. */
  label?: string
  /** Resolve a display label from the method key (e.g. i18n in the app). */
  resolveLabel?: (method: string) => string
  /** Hide the icon when space-constrained. */
  noIcon?: boolean
  size?: BadgeSize
  className?: string
}

export function PaymentMethodBadge({
  method,
  label,
  resolveLabel,
  noIcon,
  size,
  className,
}: PaymentMethodBadgeProps) {
  if (!method) {
    return <span className="text-muted-foreground">—</span>
  }

  const config = METHOD_CONFIG[method] ?? { variant: "neutral" as const, Icon: BanknoteIcon }
  const resolvedLabel = label ?? resolveLabel?.(method) ?? method
  const Icon = config.Icon

  return (
    <Badge variant={config.variant} size={size} className={cn(className)}>
      {!noIcon && <Icon className="size-3" />}
      {resolvedLabel}
    </Badge>
  )
}
