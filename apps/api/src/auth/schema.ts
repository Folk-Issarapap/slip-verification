import { z } from "@hono/zod-openapi"

export const UserSchema = z
  .object({
    id: z.string().openapi({ example: "a1b2c3d4e5f6" }),
    email: z.string().email().openapi({ example: "admin@example.com" }),
    name: z.string().nullable().openapi({ example: "Jay Park" }),
    display_name: z.string().nullable().openapi({ example: null }),
    staff_role: z.string().nullable().openapi({ example: "admin" }),
    kind: z.enum(["staff", "merchant", "reseller"]).openapi({ example: "staff" }),
    status: z.string().openapi({ example: "active" }),
    avatarUrl: z.string().nullable().openapi({ example: null }),
    preferred_language: z.string().openapi({ example: "th" }),
    /**
     * When 1, the user must rotate their password before normal app access
     * (migration 0028). Set by:
     *   - First successful password-based login when last_login_at is NULL
     *   - Admin creating a merchant owner (admin sets the temp password)
     *   - Admin reset-password (issues a new temp password)
     * Cleared by:
     *   - PATCH /v1/profile/password
     * Frontend reads this from the login + /v1/auth/me responses and
     * redirects to a password-change page until cleared.
     */
    must_change_password: z.number().openapi({ example: 0 }),
    /**
     * ISO 8601 datetime when the account's email was verified, or null if
     * not yet verified. Set by POST /v1/auth/verify-email.
     */
    email_verified_at: z.string().nullable().openapi({ example: null }),
    /** UI theme preference — 'light' | 'dark' | 'system'. Migration 0045. */
    theme: z.string().openapi({ example: "system" }),
    /** UI font size preference — 'small' | 'normal' | 'large'. Migration 0045. */
    font_size: z.string().openapi({ example: "normal" }),
    /** UI density preference — 'comfortable' | 'compact'. Migration 0045. */
    density: z.string().openapi({ example: "comfortable" }),
    /** ISO 8601 datetime when the user completed onboarding, or null. Migration 0045. */
    onboarded_at: z.string().nullable().openapi({ example: null }),
  })
  .openapi("User")

export const RegisterInputSchema = z
  .object({
    email: z.string().email("Invalid email").openapi({ example: "admin@example.com" }),
    password: z
      .string()
      .min(8, "Password must be at least 8 characters")
      .openapi({ example: "Admin123!" }),
    name: z.string().min(1, "Name is required").max(100).openapi({ example: "Jay Park" }),
  })
  .strict()
  .openapi("RegisterInput")

export const LoginInputSchema = z
  .object({
    email: z.string().email("Invalid email").openapi({ example: "admin@example.com" }),
    password: z.string().min(1, "Password is required").openapi({ example: "Admin123!" }),
    rememberMe: z.boolean().optional().default(false).openapi({ example: true }),
  })
  .strict()
  .openapi("LoginInput")

export const RefreshInputSchema = z
  .object({
    refreshToken: z.string().min(1).openapi({ example: "eyJ..." }),
  })
  .strict()
  .openapi("RefreshInput")

export const LogoutInputSchema = z
  .object({
    sessionId: z.string().min(1).openapi({ example: "abc123" }),
  })
  .strict()
  .openapi("LogoutInput")

export const GoogleExchangeInputSchema = z
  .object({
    code: z.string().min(1).openapi({ example: "abc123" }),
  })
  .strict()
  .openapi("GoogleExchangeInput")

export const TokenResponseSchema = z
  .object({
    data: z.object({
      accessToken: z.string().openapi({ example: "eyJ..." }),
      refreshToken: z.string().openapi({ example: "eyJ..." }),
      sessionId: z.string().openapi({ example: "abc123" }),
      user: UserSchema,
      /** Present on reseller login — first active can_resell merchant for `X-Merchant-Id`. */
      defaultMerchantId: z.string().optional().openapi({ example: "mrc_01hz..." }),
    }),
  })
  .openapi("TokenResponse")

export const GoogleUrlResponseSchema = z
  .object({
    data: z.object({
      url: z.string().url().openapi({ example: "https://accounts.google.com/..." }),
    }),
  })
  .openapi("GoogleUrlResponse")

export type RegisterInput = z.infer<typeof RegisterInputSchema>
export type LoginInput = z.infer<typeof LoginInputSchema>
export type AuthUser = z.infer<typeof UserSchema>
