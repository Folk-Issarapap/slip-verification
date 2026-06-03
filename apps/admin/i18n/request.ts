import { cookies } from "next/headers"
import { getRequestConfig } from "next-intl/server"

export const locales = ["en", "th"] as const
export type Locale = (typeof locales)[number]
export const defaultLocale: Locale = "th"

export default getRequestConfig(async () => {
  const cookieStore = await cookies()
  const cookie = cookieStore.get("NEXT_LOCALE")?.value
  const locale: Locale =
    cookie && (locales as readonly string[]).includes(cookie) ? (cookie as Locale) : defaultLocale

  // Explicit imports — rolldown cannot statically analyse template literals
  const messages =
    locale === "en"
      ? (await import("../messages/en.json")).default
      : (await import("../messages/th.json")).default

  return { locale, messages }
})
