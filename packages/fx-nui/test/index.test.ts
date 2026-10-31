import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { NuiError, emitMessage, fetchNui, isInGame, isNuiError, mockNui, onMessage, resourceName, setDevResource } from "../src/index.js"

type FetchArgs = [string, RequestInit]

const respond = (body: unknown, status = 200) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), { status })

const g = globalThis as Record<string, unknown>

beforeEach(() => {
  g["window"] = new EventTarget()
  g["GetParentResourceName"] = () => "shop"
})

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
  delete g["GetParentResourceName"]
})

describe("fetchNui", () => {
  it("posts JSON to https://<resource>/<name> and resolves with the value", async () => {
    const fetchMock = vi.fn(async (..._args: FetchArgs) => respond({ ok: true, value: { bought: "2x apple" } }))
    vi.stubGlobal("fetch", fetchMock)
    await expect(fetchNui("buy", { item: "apple", qty: 2 })).resolves.toEqual({ bought: "2x apple" })
    const [url, init] = fetchMock.mock.calls[0]!
    expect(url).toBe("https://shop/buy")
    expect(init.method).toBe("POST")
    expect(JSON.parse(init.body as string)).toEqual({ item: "apple", qty: 2 })
  })

  it("rejects with the handler's tag and fields", async () => {
    vi.stubGlobal("fetch", async () => respond({ ok: false, error: { _tag: "OutOfStock", item: "gold" } }))
    const err = await fetchNui("buy", { item: "gold" }).catch((e: unknown) => e)
    expect(isNuiError(err, "OutOfStock")).toBe(true)
    expect((err as NuiError).fields).toEqual({ _tag: "OutOfStock", item: "gold" })
  })

  it("reports invalid input with its message", async () => {
    vi.stubGlobal("fetch", async () =>
      respond({ ok: false, error: { _tag: "NuiInvalidInput", name: "buy", message: "qty: expected at most 10" } }))
    const err = (await fetchNui("buy", {}).catch((e: unknown) => e)) as NuiError
    expect(err._tag).toBe("NuiInvalidInput")
    expect(err.message).toBe("NuiInvalidInput: qty: expected at most 10")
  })

  it("passes plain (non-envelope) callback answers through", async () => {
    vi.stubGlobal("fetch", async () => respond("ok"))
    await expect(fetchNui("legacy")).resolves.toBe("ok")
  })

  it("times out with NuiTimeout", async () => {
    vi.stubGlobal("fetch", (_url: string, init: RequestInit) =>
      new Promise((_, reject) => init.signal?.addEventListener("abort", () => reject(new Error("aborted")))))
    const err = (await fetchNui("slow", {}, { timeout: 20 }).catch((e: unknown) => e)) as NuiError
    expect(err._tag).toBe("NuiTimeout")
    expect(err.fields["timeoutMs"]).toBe(20)
  })

  it("turns HTTP and network failures into NuiTransportError", async () => {
    vi.stubGlobal("fetch", async () => respond("nope", 404))
    expect(((await fetchNui("x").catch((e: unknown) => e)) as NuiError)._tag).toBe("NuiTransportError")
    vi.stubGlobal("fetch", async () => {
      throw new TypeError("Failed to fetch")
    })
    expect(((await fetchNui("x").catch((e: unknown) => e)) as NuiError).fields["message"]).toBe("Failed to fetch")
  })

  it("uses mocks only outside the game", async () => {
    const remove = mockNui<{ qty: number }, number>("buy", (input) => input.qty * 2)
    vi.stubGlobal("fetch", async () => respond({ ok: true, value: "from game" }))
    await expect(fetchNui("buy", { qty: 2 })).resolves.toBe("from game")
    delete g["GetParentResourceName"]
    expect(isInGame()).toBe(false)
    await expect(fetchNui("buy", { qty: 2 })).resolves.toBe(4)
    remove()
    setDevResource("my_shop")
    expect(resourceName()).toBe("my_shop")
  })
})

describe("messages", () => {
  it("delivers matching messages until unsubscribed", () => {
    const seen: unknown[] = []
    const stop = onMessage<{ n: number }>("tick", (p) => seen.push(p.n))
    emitMessage("tick", { n: 1 })
    emitMessage("other", { n: 2 })
    stop()
    emitMessage("tick", { n: 3 })
    expect(seen).toEqual([1])
  })
})
