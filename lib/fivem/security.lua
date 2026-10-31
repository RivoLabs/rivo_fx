-- SecurityEvents: what the server rejected from clients.
--   Fx.security.on(function(ev) ... end)
-- ev = { kind = "invalid_payload" | "rate_limited" | "unknown_rpc" | "invalid_state", source, name, message }
-- Also fired as TriggerEvent("rivo_fx:security", ev, resourceName) for anticheats.
return function(Fx)
  local security = {}
  security.events = Fx.PubSub.unsafeMake()
  local Counted = Fx.metrics.counter('rivo_fx_security_events_total', { help = 'Rejected client input, by kind' })

  ---Listen to security events in this resource. Returns an unsubscribe function.
  function security.on(fn) return security.events:on(fn) end

  ---Scoped Queue of security events.
  function security.subscribe() return security.events:subscribe() end

  ---Security events as a stream, from when it starts. opts.buffer (default
  ---1024) caps how many wait for a slow consumer; past that the oldest go.
  function security.stream(opts)
    return Fx.Stream.fromPubSub(security.events, { buffer = opts and opts.buffer or 1024, strategy = 'sliding' })
  end

  local quiet = false
  ---Stop logging each event (they are still published).
  function security.setQuiet(v) quiet = v end

  function security.report(ev)
    ev.resource = Fx.resourceName
    Counted:inc(1, { kind = ev.kind })
    if not quiet then
      local write = ev.kind == 'rate_limited' and Fx.log.debug or Fx.log.warn
      write(('security: %s from player %s on %s'):format(ev.kind, tostring(ev.source), tostring(ev.name)),
        ev.message and { message = ev.message } or nil)
    end
    security.events:unsafePublish(ev)
    if TriggerEvent then TriggerEvent('rivo_fx:security', ev, Fx.resourceName) end
  end

  return security
end
