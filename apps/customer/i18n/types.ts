import type en from "../messages/en.json"

type EnMessages = typeof en

// next-intl reads the global IntlMessages interface for type-safe keys
declare global {
  interface IntlMessages extends EnMessages {}
}
