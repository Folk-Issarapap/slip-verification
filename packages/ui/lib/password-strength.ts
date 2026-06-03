/**
 * Lightweight password strength scorer — no dependencies.
 *
 * Intended as a UX nudge (not a security guarantee). For real security,
 * combine with server-side policy + breach-password check (e.g. Pwned
 * Passwords k-anonymity lookup).
 *
 * Scoring rules:
 *   length ≥ 8     : +1
 *   length ≥ 12    : +1
 *   has lowercase  : +1
 *   has uppercase  : +1
 *   has digit      : +1
 *   has symbol     : +1
 *
 * Score → strength:
 *   0-2 → weak
 *   3   → fair
 *   4   → good
 *   5-6 → strong
 */

export type PasswordStrength = "weak" | "fair" | "good" | "strong"

export interface PasswordScore {
  /** Raw score 0..6 — useful for filling segmented meter bars */
  score: number
  /** Mapped strength bucket — useful for labels and colours */
  strength: PasswordStrength
}

export function scorePassword(value: string): PasswordScore {
  if (!value) return { score: 0, strength: "weak" }

  let score = 0
  if (value.length >= 8) score += 1
  if (value.length >= 12) score += 1
  if (/[a-z]/.test(value)) score += 1
  if (/[A-Z]/.test(value)) score += 1
  if (/[0-9]/.test(value)) score += 1
  if (/[^A-Za-z0-9]/.test(value)) score += 1

  let strength: PasswordStrength
  if (score <= 2) strength = "weak"
  else if (score === 3) strength = "fair"
  else if (score === 4) strength = "good"
  else strength = "strong"

  return { score, strength }
}
