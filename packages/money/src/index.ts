/**
 * Utility functions for Satang <-> THB conversions
 */

export function thbToSatang(thb: number): number {
  return Math.round(thb * 100)
}

export function satangToThb(satang: number): number {
  return satang / 100
}

export function formatThb(satang: number): string {
  return new Intl.NumberFormat("th-TH", {
    style: "currency",
    currency: "THB",
  }).format(satangToThb(satang))
}
