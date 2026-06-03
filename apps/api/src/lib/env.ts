import { z } from "@hono/zod-openapi"

const EnvSchema = z
  .object({
    DB: z.custom<D1Database>(),
    ALLOWED_ORIGINS: z.string().min(1).default("*"),
    ENVIRONMENT: z.string().default("local"),
  })

export type Env = z.infer<typeof EnvSchema>

export function validateEnv(env: Record<string, unknown>): Env {
  return EnvSchema.parse(env)
}
