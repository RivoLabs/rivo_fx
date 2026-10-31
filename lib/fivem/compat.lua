-- Interop with ox_lib callbacks, for moving a codebase over step by step.
return function(Fx)
  local compat = {}

  local function lib()
    local l = rawget(_G, 'lib')
    if not (l and l.callback) then
      error('Fx.compat: ox_lib is not loaded in this resource (add @ox_lib/init.lua)', 3)
    end
    return l
  end

  ---Also expose an Fx RPC handler as an ox_lib callback, so existing
  ---lib.callback callers keep working. Used by Fx.rpc.register when
  ---spec.libCallback = true. Input is the first callback argument.
  function compat.registerLibCallback(name, spec, handler, limiter)
    lib().callback.register(name, function(a, b)
      local src, input
      if Fx.isServer then src, input = a, b else input = a end
      if limiter and src and not limiter:take(src) then
        Fx.security.report({ kind = 'rate_limited', source = src, name = name })
        return nil
      end
      local ok, value = spec.input:validate(input)
      if not ok then
        if Fx.isServer then
          Fx.security.report({ kind = 'invalid_payload', source = src, name = name, message = value })
        end
        return nil
      end
      local r
      if Fx.isServer then r = handler(src, value) else r = handler(value) end
      local eff = Fx.isEffect(r) and r or Fx.succeed(r)
      if spec.output then
        eff = eff:flatMap(function(v)
          local okOut, out = spec.output:validate(v)
          if okOut then return Fx.succeed(out) end
          return Fx.die(('rpc %q returned invalid output: %s'):format(name, out))
        end)
      end
      local rt = spec.runtime or Fx._runtime
      local exit = Fx._platform.current.suspend(function(resolve)
        if rt then rt:runFork(eff, { onExit = resolve }) else Fx.runFork(eff, { onExit = resolve }) end
      end)
      if exit._tag == 'Success' then return exit.value end
      Fx.log.error(('lib callback %q failed'):format(name), { cause = Fx.Cause.pretty(exit.cause) })
      return nil
    end)
  end

  ---Call an ox_lib callback as an effect (client: server callback; server: client callback).
  ---Fails with RpcTimeout after opts.timeout ms (default 10000).
  function compat.libCallback(name, ...)
    local args = table.pack(...)
    local opts = {}
    if type(args[args.n]) == 'table' and args[args.n].__fxOpts then
      opts = args[args.n]
      args.n = args.n - 1
    end
    local timeout = opts.timeout or 10000
    return Fx.async(function(resume)
      local cb = function(...) resume(Fx.succeed((...))) end
      if Fx.isServer then
        lib().callback(name, args[1], cb, table.unpack(args, 2, args.n))
      else
        lib().callback(name, false, cb, table.unpack(args, 1, args.n))
      end
    end):timeoutFail(timeout, function() return Fx.rpc.RpcTimeout { name = name, timeoutMs = timeout } end)
  end

  ---Options marker for compat.libCallback: Fx.compat.opts { timeout = 5000 }
  function compat.opts(t)
    t.__fxOpts = true
    return t
  end

  return compat
end
