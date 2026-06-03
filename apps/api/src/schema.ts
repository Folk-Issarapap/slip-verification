import { z } from "@hono/zod-openapi"

export const GenericSchema = z.object({
  id: z.string(),
})

export type Generic = z.infer<typeof GenericSchema>
