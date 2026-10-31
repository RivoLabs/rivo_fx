-- Typed NUI messages and callbacks (client). Pairs with @rivolabs/fx-nui in the page.
--   Fx.nui.handle('buy', { input = S.struct { item = S.string, qty = S.int:between(1, 10) } },
--     function(input) return Shop.buy(input.item, input.qty) end)
--   Fx.yield(Fx.nui.send('open', { items = items }))
-- A callback answers { ok = true, value } or { ok = false, error = { _tag, ... } }:
-- input that fails its schema is NuiInvalidInput, a tagged failure from the
-- handler is sent as is, and anything else is NuiInternalError (details are
-- logged here, never sent to the page).
return function(Fx)
  local nui = {}

  nui.NuiInvalidInput = Fx.TaggedError('NuiInvalidInput')
  nui.NuiInvalidMessage = Fx.TaggedError('NuiInvalidMessage')

  local function encodeFailure(name, cause)
    local e = Fx.Cause.failureOption(cause)
    if e ~= nil and #Fx.Cause.defects(cause) == 0 and type(e) == 'table' and type(e._tag) == 'string' then
      return Fx.serializeError(e)
    end
    Fx.log.error(('nui callback %q failed'):format(name), { cause = Fx.Cause.pretty(cause) })
    return { _tag = 'NuiInternalError', name = name }
  end

  ---Answer the page's fetch('https://<resource>/<name>', ...) with a typed
  ---handler. spec.input checks the body; spec.output (optional) checks the
  ---answer. handler(input) returns a value or an effect.
  ---@param name string
  ---@param spec { input: Fx.Schema, output?: Fx.Schema }
  ---@param handler fun(input: any): any
  function nui.handle(name, spec, handler)
    assert(spec and spec.input, ('Fx.nui.handle(%q): spec.input (a schema) is required'):format(name))
    RegisterNUICallback(name, function(data, cb)
      local ok, input = spec.input:validate(data)
      if not ok then
        cb({ ok = false, error = { _tag = 'NuiInvalidInput', name = name, message = input } })
        return
      end
      local eff = Fx.suspend(function()
        local r = handler(input)
        return Fx.isEffect(r) and r or Fx.succeed(r)
      end)
      if spec.output then
        eff = eff:flatMap(function(v)
          local okOut, out = spec.output:validate(v)
          if okOut then return Fx.succeed(out) end
          return Fx.die(('nui callback %q returned invalid output: %s'):format(name, out))
        end)
      end
      Fx.runFork(eff, {
        onExit = function(exit)
          if exit._tag == 'Success' then
            cb({ ok = true, value = exit.value })
          elseif Fx.Cause.isInterruptedOnly(exit.cause) then
            -- never leave the page's fetch hanging
            cb({ ok = false, error = { _tag = 'NuiInterrupted', name = name } })
          else
            cb({ ok = false, error = encodeFailure(name, exit.cause) })
          end
        end,
      })
    end)
  end

  ---Send { type = type, payload = payload } to the page (window 'message').
  ---With a schema the payload is checked first; a bad one fails NuiInvalidMessage.
  ---@param msgType string
  ---@param payload? any
  ---@param schema? Fx.Schema
  function nui.send(msgType, payload, schema)
    return Fx.suspend(function()
      if schema then
        local ok, v = schema:validate(payload)
        if not ok then return Fx.fail(nui.NuiInvalidMessage { type = msgType, message = v }) end
        payload = v
      end
      SendNUIMessage({ type = msgType, payload = payload })
      return Fx.unit
    end)
  end

  ---Give the page keyboard focus (and the cursor, unless opts.cursor is false)
  ---for the rest of the scope; focus goes back to the game when it closes.
  ---@param opts? { cursor?: boolean, keepInput?: boolean }
  function nui.useFocus(opts)
    local cursor = not (opts and opts.cursor == false)
    return Fx.acquireRelease(
      Fx.sync(function()
        SetNuiFocus(true, cursor)
        if opts and opts.keepInput then SetNuiFocusKeepInput(true) end
      end),
      function()
        return Fx.sync(function()
          SetNuiFocus(false, false)
          if opts and opts.keepInput then SetNuiFocusKeepInput(false) end
        end)
      end
    )
  end

  return nui
end
