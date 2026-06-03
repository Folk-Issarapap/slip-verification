/** Max upload size (bytes) — must match API `profile` avatar handler. */
export const MAX_AVATAR_FILE_BYTES = 5 * 1024 * 1024

/**
 * Client-side cache bust for <img> when the URL path is unchanged after upload.
 * Strip `t` / other view params before persisting to the API.
 */
export function withAvatarCacheBust(
  url: string | null | undefined,
  baseForRelative?: string
): string {
  if (!url) return ""
  const base =
    baseForRelative ?? (typeof window !== "undefined" ? window.location.href : "http://localhost")
  try {
    const u = new URL(url, base)
    u.searchParams.set("t", String(Date.now()))
    return u.toString()
  } catch {
    const sep = url.includes("?") ? "&" : "?"
    return `${url}${sep}t=${Date.now()}`
  }
}

export function stripAvatarViewParam(url: string, baseForRelative?: string): string {
  if (!url) return ""
  const base =
    baseForRelative ?? (typeof window !== "undefined" ? window.location.href : "http://localhost")
  try {
    const u = new URL(url, base)
    u.searchParams.delete("t")
    const s = u.toString()
    return s.endsWith("?") ? s.slice(0, -1) : s
  } catch {
    return url.replace(/[?&]t=\d+/, "").replace(/\?$/, "")
  }
}
