import { afterEach, describe, expect, it, vi } from "vitest"

// FiveM's client runtime has no TextEncoder or TextDecoder; effect needs both at load.
type Enc = new () => { encode(s: string): Uint8Array }
type Dec = new () => { decode(b: Uint8Array): string }
const g = globalThis as Record<string, unknown>
const Native = { TextEncoder: g["TextEncoder"] as Enc, TextDecoder: g["TextDecoder"] as Dec }

afterEach(() => {
  g["TextEncoder"] = Native.TextEncoder
  g["TextDecoder"] = Native.TextDecoder
})

describe("@rivolabs/fx/polyfill", () => {
  it("installs a UTF-8 TextEncoder and TextDecoder when the runtime has none", async () => {
    delete g["TextEncoder"]
    delete g["TextDecoder"]
    vi.resetModules()
    await import("../../src/polyfill.js")
    const Enc = g["TextEncoder"] as Enc
    const Dec = g["TextDecoder"] as Dec
    expect(Enc).not.toBe(Native.TextEncoder)

    for (const s of ["", "plain ascii", "Rivo · Internal Dev", "£€¥", "😀 emoji 𝄞", "\u0000\u007f\u0080߿ࠀ￿"]) {
      const bytes = new Enc().encode(s)
      expect(Array.from(bytes)).toEqual(Array.from(new Native.TextEncoder().encode(s)))
      expect(new Dec().decode(bytes)).toBe(s)
    }
  })

  it("lets effect load and run without native TextEncoder", async () => {
    delete g["TextEncoder"]
    delete g["TextDecoder"]
    vi.resetModules()
    await import("../../src/polyfill.js")
    const { Effect } = await import("effect")
    expect(Effect.runSync(Effect.succeed(2).pipe(Effect.map((n) => n * 21)))).toBe(42)
  })

  it("leaves existing globals alone", async () => {
    vi.resetModules()
    await import("../../src/polyfill.js")
    expect(g["TextEncoder"]).toBe(Native.TextEncoder)
  })
})
