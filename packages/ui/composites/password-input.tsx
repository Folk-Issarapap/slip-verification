"use client"

import { EyeIcon, EyeOffIcon, LockIcon } from "lucide-react"
import * as React from "react"
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
} from "../components/input-group"
import { type PasswordStrength, scorePassword } from "../lib/password-strength"
import { cn } from "../lib/utils"

export interface PasswordInputStrengthLabels {
  weak: string
  fair: string
  good: string
  strong: string
}

export interface PasswordInputProps extends Omit<React.ComponentProps<"input">, "type"> {
  /** Show segmented strength meter + label under the input (default: false) */
  showStrength?: boolean
  /** aria-label when the password is currently hidden (toggle will reveal) */
  showPasswordLabel?: string
  /** aria-label when the password is currently visible (toggle will hide) */
  hidePasswordLabel?: string
  /** Translated labels per strength bucket */
  strengthLabels?: PasswordInputStrengthLabels
  /**
   * Leading icon (defaults to LockIcon). Pass `null` to remove the leading addon
   * entirely — useful when the field already has a contextual label elsewhere.
   */
  leadingIcon?: React.ReactNode | null
  /** Class applied to the outer wrapper (input + strength meter) */
  wrapperClassName?: string
}

const DEFAULT_STRENGTH_LABELS: PasswordInputStrengthLabels = {
  weak: "Weak",
  fair: "Fair",
  good: "Good",
  strong: "Strong",
}

const STRENGTH_FILLED_SEGMENTS: Record<PasswordStrength, number> = {
  weak: 1,
  fair: 2,
  good: 3,
  strong: 4,
}

const STRENGTH_COLORS: Record<PasswordStrength, string> = {
  weak: "bg-destructive",
  fair: "bg-amber-500",
  good: "bg-blue-500",
  strong: "bg-emerald-500",
}

const STRENGTH_TEXT_COLORS: Record<PasswordStrength, string> = {
  weak: "text-destructive",
  fair: "text-amber-600 dark:text-amber-400",
  good: "text-blue-600 dark:text-blue-400",
  strong: "text-emerald-600 dark:text-emerald-400",
}

export const PasswordInput = React.forwardRef<HTMLInputElement, PasswordInputProps>(
  function PasswordInput(
    {
      showStrength = false,
      showPasswordLabel = "Show password",
      hidePasswordLabel = "Hide password",
      strengthLabels = DEFAULT_STRENGTH_LABELS,
      leadingIcon = <LockIcon />,
      wrapperClassName,
      className,
      value,
      defaultValue,
      onChange,
      autoComplete = "current-password",
      ...props
    },
    ref
  ) {
    const [visible, setVisible] = React.useState(false)
    // Mirror value internally so the strength meter works in both controlled
    // and uncontrolled mode without consumers needing to pass `value` explicitly.
    const [internal, setInternal] = React.useState<string>(
      typeof value === "string" ? value : typeof defaultValue === "string" ? defaultValue : ""
    )

    // Sync when controlled value changes externally
    React.useEffect(() => {
      if (typeof value === "string") setInternal(value)
    }, [value])

    const currentValue = typeof value === "string" ? value : internal
    const { score, strength } = scorePassword(currentValue)
    const showMeter = showStrength && currentValue.length > 0

    return (
      <div className={cn("flex flex-col gap-1.5", wrapperClassName)}>
        <InputGroup>
          {leadingIcon !== null && (
            <InputGroupAddon align="inline-start">{leadingIcon}</InputGroupAddon>
          )}
          <InputGroupInput
            ref={ref}
            type={visible ? "text" : "password"}
            value={value}
            defaultValue={defaultValue}
            onChange={(e) => {
              setInternal(e.target.value)
              onChange?.(e)
            }}
            autoComplete={autoComplete}
            className={className}
            {...props}
          />
          <InputGroupAddon align="inline-end">
            <InputGroupButton
              type="button"
              size="icon-xs"
              aria-label={visible ? hidePasswordLabel : showPasswordLabel}
              onClick={() => setVisible((v) => !v)}
              tabIndex={-1}
            >
              {visible ? <EyeOffIcon /> : <EyeIcon />}
            </InputGroupButton>
          </InputGroupAddon>
        </InputGroup>

        {showMeter && (
          <div
            className="flex items-center gap-2"
            aria-live="polite"
            data-password-strength={strength}
          >
            <div className="flex flex-1 gap-1" aria-hidden="true">
              {[0, 1, 2, 3].map((i) => (
                <div
                  key={i}
                  className={cn(
                    "h-1 flex-1 rounded-full transition-colors",
                    i < STRENGTH_FILLED_SEGMENTS[strength] ? STRENGTH_COLORS[strength] : "bg-muted"
                  )}
                />
              ))}
            </div>
            <span
              className={cn("text-xs font-medium tabular-nums", STRENGTH_TEXT_COLORS[strength])}
            >
              {strengthLabels[strength]}
            </span>
            <span className="sr-only">Password strength score: {score} of 6</span>
          </div>
        )}
      </div>
    )
  }
)
