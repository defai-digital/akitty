import { defineConfig } from "vite"
import { fileURLToPath } from "node:url"

export default defineConfig({
  clearScreen: false,
  resolve: { alias: { "@akitty/web": fileURLToPath(new URL("../packages/akitty-web/lib/index.ts", import.meta.url)) } },
  server: { fs: { allow: [fileURLToPath(new URL("..", import.meta.url))] } },
  build: { target: "es2022", assetsInlineLimit: 0 }
})
