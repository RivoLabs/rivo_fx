import { defineConfig } from "tsup"

// Server and client typings declare conflicting FiveM globals, so each side is
// built (and its .d.ts generated) against its own tsconfig.
const common = {
  format: ["esm", "cjs"] as const,
  target: "es2020",
  platform: "neutral" as const,
  external: ["effect"],
  sourcemap: true,
  treeshake: true
}

export default defineConfig([
  {
    ...common,
    entry: { index: "src/index.ts", server: "src/server/index.ts" },
    tsconfig: "tsconfig.server.json",
    dts: { compilerOptions: { types: ["@citizenfx/server"] } },
    clean: true
  },
  {
    ...common,
    entry: { client: "src/client/index.ts", polyfill: "src/polyfill.ts" },
    // keep the polyfill inside client.js instead of a shared chunk, so
    // "sideEffects" can name the files that install it
    splitting: false,
    tsconfig: "tsconfig.client.json",
    dts: { compilerOptions: { types: ["@citizenfx/client"] } }
  }
])
