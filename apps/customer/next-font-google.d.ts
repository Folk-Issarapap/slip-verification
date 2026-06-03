declare module "next/font/google" {
  export * from "next/dist/compiled/@next/font/dist/google"
  export { default } from "next/dist/compiled/@next/font/dist/google"

  export function createFontLoader(family: string): (options: {
    subsets?: string[]
    variable?: string
    weight?: string | string[]
  }) => {
    className: string
    style: { fontFamily: string; fontWeight?: number; fontStyle?: string }
    variable: string
  }
}
