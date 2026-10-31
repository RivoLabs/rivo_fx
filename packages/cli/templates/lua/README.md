# __NAME__

Made with [Rivo FX](https://github.com/RivoLabs/rivo_fx).

- `shared/schemas.json` describes the payloads once. After editing it, run
  `npx rivo-fx gen shared/schemas.json --lua shared/schemas.lua --namespace __NAMESPACE__`.
- `server.lua` registers `__NAME__:buy`: input and output are checked against the
  schemas, players are rate limited, and money moves through the running
  framework (`Fx.framework.auto`).
- `client.lua` adds `/__NAME__ <item> [qty]` and handles the typed failures.

`.luarc.json` points LuaLS at `../rivo_fx/types` (rivo_fx next to this
resource); change the path if yours lives elsewhere.

Start it after `rivo_fx` (and your framework) in `server.cfg`:

```
ensure rivo_fx
ensure __NAME__
```
