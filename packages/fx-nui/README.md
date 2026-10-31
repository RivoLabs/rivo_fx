# @rivolabs/fx-nui

Typed `fetchNui` and NUI messages for [Rivo FX](https://github.com/RivoLabs/rivo_fx) pages. No dependencies, about 3 KB, and works in React, Svelte, Vue or plain JS.

```sh
npm install @rivolabs/fx-nui
```

```ts
import { fetchNui, onMessage, isNuiError } from "@rivolabs/fx-nui"

try {
  const { bought } = await fetchNui<{ bought: string }>("buy", { item: "apple", qty: 2 })
} catch (e) {
  if (isNuiError(e, "OutOfStock")) showSoldOut()
}

onMessage<{ items: string[] }>("open", ({ items }) => render(items))
```

It pairs with `Fx.nui.handle` and `Fx.nui.send` in the resource's Lua:

- A callback answers with its value, or rejects with the typed error the handler failed with. Input that fails the handler's schema rejects as `NuiInvalidInput`.
- Anything unexpected rejects as `NuiInternalError`, and its details stay in the server log.

Outside the game, `mockNui(name, fn)` answers calls so the page runs in a normal browser.

MIT licensed.
