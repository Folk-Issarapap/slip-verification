import type { Hook } from "@hono/zod-openapi"

/**
 * Shared defaultHook for all OpenAPIHono instances.
 * Converts Zod validation failures into our standard error envelope.
 * Must be applied to EVERY OpenAPIHono instance (main app + sub-routers).
 */
// biome-ignore lint/suspicious/noExplicitAny: Hono Hook type requires any for cross-router compatibility
export const validationHook: Hook<any, any, any, any> = (result, c) => {
  if (!result.success) {
    const flat = result.error.flatten()
    return c.json(
      {
        error: {
          code: "VALIDATION_ERROR",
          message: "Invalid request data",
          details: {
            ...flat.fieldErrors,
            ...(flat.formErrors.length > 0 ? { _form: flat.formErrors } : {}),
          },
        },
      },
      400
    )
  }
}
