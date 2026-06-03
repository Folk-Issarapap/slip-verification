import { resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import vinext from "vinext"
import { defineConfig } from "vite"

const __dirname = fileURLToPath(new URL(".", import.meta.url))

export default defineConfig(({ command }) => ({
  plugins: [
    tailwindcss(),
    vinext(),
    ...(command === "serve"
      ? []
      : [cloudflare({ viteEnvironment: { name: "rsc", childEnvironments: ["ssr"] } })]),
  ],
  resolve: {
    // pnpm strict hoisting: rolldown can't resolve transitive deps from
    // @workspace/ui through the virtual store. Dedupe ensures a single
    // copy resolves from web's own node_modules.
    dedupe: ["react", "react-dom", "zod", "recharts"],
    alias: {
      // next-intl/config is normally aliased by the webpack plugin;
      // vinext uses vite/rolldown so we wire it manually here.
      "next-intl/config": resolve(__dirname, "./i18n/request.ts"),
      // @hookform/resolvers@5.x imports "zod/v4/core" which rolldown
      // can't locate via pnpm's virtual store without an explicit alias.
      "zod/v4/core": resolve(__dirname, "node_modules/zod/v4/core"),
    },
  },
  build: {
    rollupOptions: {
      external: ["cloudflare:workers"],
    },
  },
}))
