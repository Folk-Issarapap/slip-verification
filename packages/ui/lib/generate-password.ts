/**
 * Generate a random password suitable for initial / temp credentials.
 * Uses `crypto.getRandomValues` — length ≥ 12 with mixed case, digit, and symbol
 * so it typically scores "strong" with `scorePassword` and passes common API min length.
 */
const LOWER = "abcdefghijkmnopqrstuvwxyz" // no l
const UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ" // no I, O
const DIGIT = "23456789" // no 0,1
const SYMBOL = "!@#$%&*-_"

export function generateRandomPassword(length = 16): string {
  const len = Math.max(12, length)
  const bytes = new Uint8Array(len)
  crypto.getRandomValues(bytes)

  const pick = (pool: string, i: number) => pool[bytes[i] % pool.length]

  // Ensure at least one of each class (indices 0–3 fixed, then shuffle)
  const chars = [pick(LOWER, 0), pick(UPPER, 1), pick(DIGIT, 2), pick(SYMBOL, 3)]
  const all = LOWER + UPPER + DIGIT + SYMBOL
  for (let i = 4; i < len; i++) {
    chars.push(pick(all, i))
  }

  const shuffleBytes = new Uint8Array(len)
  crypto.getRandomValues(shuffleBytes)
  for (let i = chars.length - 1; i > 0; i--) {
    const j = shuffleBytes[i % shuffleBytes.length] % (i + 1)
    ;[chars[i], chars[j]] = [chars[j], chars[i]]
  }

  return chars.join("")
}
