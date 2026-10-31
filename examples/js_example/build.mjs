// Bundles src/server.ts and src/client.ts (with @rivolabs/fx and effect) into dist/.
// Uses the esbuild and effect installed in packages/fx; run `pnpm -C packages/fx build` first.
import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const fx = join(here, "..", "..", "packages", "fx")
const esbuild = await import(pathToFileURL(createRequire(join(fx, "package.json")).resolve("esbuild")).href)

/** Resolves `@rivolabs/fx/<entry>` to the package's built ESM output. */
const rivoFx = {
  name: "rivo-fx",
  setup(build) {
    build.onResolve({ filter: /^@rivolabs\/fx(\/(server|client|polyfill))?$/ }, (args) => ({
      path: join(fx, "dist", `${args.path.split("/")[2] ?? "index"}.js`)
    }))
  }
}

export async function build() {
  await Promise.all(["server", "client"].map((side) =>
    esbuild.build({
      entryPoints: [join(here, "src", `${side}.ts`)],
      outfile: join(here, "dist", `${side}.js`),
      bundle: true,
      format: "iife",
      platform: "neutral",
      target: "es2020",
      mainFields: ["module", "main"],
      nodePaths: [join(fx, "node_modules")],
      plugins: [rivoFx],
      logLevel: "warning"
    })
  ))
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await build()
