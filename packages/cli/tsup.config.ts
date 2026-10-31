import { defineConfig } from "tsup"

export default defineConfig({
  entry: { cli: "src/bin.ts", index: "src/index.ts" },
  format: ["esm"],
  target: "node20",
  platform: "node",
  dts: { entry: { index: "src/index.ts" } },
  sourcemap: true,
  clean: true,
  // bundle the page helper so `rivo-fx create --template lua-nui` works offline
  onSuccess: async () => {
    const { copyFileSync, existsSync, mkdirSync } = await import("node:fs")
    const built = "../fx-nui/dist/index.js"
    if (!existsSync(built)) throw new Error("build packages/fx-nui first (pnpm -C packages/fx-nui build)")
    mkdirSync("vendor", { recursive: true })
    copyFileSync(built, "vendor/fx-nui.js")
  }
})
