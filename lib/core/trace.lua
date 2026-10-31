-- Tracing: spans around effects.
--
--   Bank.deposit(src, amount):withSpan('bank.deposit', { attributes = { amount = amount } })
--
-- A span records a name, start and end time, a status and attributes. The
-- span an effect runs in is the parent of the spans it starts, also on fibers
-- it forks, and Fx.rpc carries it to the other side as a W3C traceparent.
-- Finished spans go to Fx.trace.on(fn) listeners, Fx.trace.stream(), and a
-- ring buffer of the most recent ones (Fx.trace.recent()). Effect logs
-- (Fx.logInfo, ...) carry the trace and span ids.
-- The convar rivo_fx:tracing = off turns span recording off.
return function(Fx)
  local P = Fx._platform
  local Effect = Fx.Effect

  local trace = {}
  Fx.trace = trace

  local CurrentSpan = Fx.Tag('rivo_fx/CurrentSpan')
  trace.CurrentSpan = CurrentSpan

  local enabled = not (GetConvar and GetConvar('rivo_fx:tracing', 'on') == 'off')
  ---Turn span recording on or off (overrides the convar).
  function trace.setEnabled(v) enabled = v and true or false end
  function trace.isEnabled() return enabled end

  -- Unix seconds. A FiveM client's os.time can answer 0; the network clock
  -- (GetCloudTimeAsInt) is the fallback.
  local function wallSeconds()
    local t = os and os.time and os.time() or 0
    if t < 1e9 and GetCloudTimeAsInt then t = GetCloudTimeAsInt() end
    return t
  end

  -- Unix ms from the platform clock, anchored to the wall clock once.
  local anchorWall, anchorMono, anchorPlatform
  local function nowMs()
    local p = P.current
    if anchorPlatform ~= p then
      anchorPlatform = p
      anchorWall = wallSeconds() * 1000
      anchorMono = p.now()
    end
    return anchorWall + (p.now() - anchorMono)
  end
  trace.nowMs = nowMs

  local random, format = math.random, string.format
  local ZERO64, ZERO128 = ('0'):rep(16), ('0'):rep(32)
  local MAXINT = math.maxinteger
  local function id64()
    local s
    repeat s = format('%016x', random(0, MAXINT)) until s ~= ZERO64
    return s
  end
  local function id128()
    local s
    repeat s = id64() .. id64() until s ~= ZERO128
    return s
  end

  local Span = {}
  Span.__index = Span
  trace.Span = Span

  local MAX_EVENTS = 32
  local noteFailure

  function Span:setAttribute(key, value)
    self.attributes[key] = value
    return self
  end

  ---A timestamped note inside the span (at most 32 per span).
  function Span:addEvent(name, attributes)
    local ev = self.events
    if not ev then
      ev = {}
      self.events = ev
    end
    if #ev < MAX_EVENTS then ev[#ev + 1] = { name = name, time = nowMs(), attributes = attributes } end
    return self
  end

  ---The W3C traceparent header value for this span.
  function Span:traceparent()
    return ('00-%s-%s-01'):format(self.traceId, self.spanId)
  end

  ---Parse a W3C traceparent. Returns { traceId, spanId } or nil.
  function trace.parseTraceparent(s)
    if type(s) ~= 'string' or #s ~= 55 then return nil end
    local version, traceId, spanId = s:match('^(%x%x)%-(%x+)%-(%x+)%-%x%x$')
    if not version or version == 'ff' or #traceId ~= 32 or #spanId ~= 16 then return nil end
    traceId, spanId = traceId:lower(), spanId:lower()
    if traceId == ZERO128 or spanId == ZERO64 then return nil end
    return { traceId = traceId, spanId = spanId, remote = true }
  end

  -- Finished spans ------------------------------------------------------------

  trace.events = Fx.PubSub.unsafeMake()
  local RING = 200
  local ring, ringNext, seq = {}, 1, 0

  ---The most recent finished spans, oldest first. With after, only spans
  ---whose seq (their order of finishing in this resource) is greater.
  function trace.recent(after)
    after = after or 0
    local out = {}
    for i = 0, RING - 1 do
      local s = ring[(ringNext + i - 1) % RING + 1]
      if s and s.seq > after then out[#out + 1] = s end
    end
    return out
  end

  ---Listen to finished spans. Returns an unsubscribe function.
  function trace.on(fn) return trace.events:on(fn) end

  ---Finished spans as a stream, from when it starts.
  function trace.stream(opts)
    return Fx.Stream.fromPubSub(trace.events, { buffer = opts and opts.buffer or 1024, strategy = 'sliding' })
  end

  ---Start a span by hand; end it with trace.finish(span, exit?). Prefer
  ---eff:withSpan, which does both. parent is a span, a parsed traceparent,
  ---or nil for a new trace.
  function trace.start(name, parent, opts)
    local attrs = {}
    if opts and opts.attributes then for k, v in pairs(opts.attributes) do attrs[k] = v end end
    return setmetatable({
      name = name,
      traceId = parent and parent.traceId or id128(),
      spanId = id64(),
      parentSpanId = parent and parent.spanId or nil,
      kind = opts and opts.kind or 'internal',
      startTime = nowMs(),
      status = 'unset',
      attributes = attrs,
      resource = Fx.resourceName,
    }, Span)
  end

  local function describeFailure(cause)
    local e = Fx.Cause.failureOption(cause)
    if e ~= nil and #Fx.Cause.defects(cause) == 0 then
      if type(e) == 'table' and type(e._tag) == 'string' then
        -- a tag rebuilt from another side is not ours to trust as a label
        local tag = Fx._declaredTags[e._tag] and e._tag or 'error'
        return e._tag, tag
      end
      return tostring(e), nil
    end
    local msg = Fx.Cause.pretty(cause)
    return (msg:match('^[^\n]*')), 'defect'
  end

  ---End a span. exit (optional) sets the status: ok, error (with message
  ---and the error tag as fx.error), or unset with fx.interrupted for an
  ---interruption.
  function trace.finish(span, exit)
    if span.endTime then return end
    span.endTime = nowMs()
    if exit then
      if exit._tag == 'Success' then
        span.status = 'ok'
      elseif Fx.Cause.isInterruptedOnly(exit.cause) then
        span.attributes['fx.interrupted'] = true
      else
        local message, tag = describeFailure(exit.cause)
        span.status = 'error'
        if #message > 256 then message = message:sub(1, 256) .. '...' end
        span.message = message
        if tag then span.attributes['fx.error'] = tag end
      end
    end
    seq = seq + 1
    span.seq = seq
    ring[ringNext] = span
    ringNext = ringNext % RING + 1
    trace.events:unsafePublish(span)
  end

  -- The span a failure was raised in, for reports after the span has closed
  -- (an unhandled failure is reported by the fiber, outside every span).
  -- Keyed by the cause itself: it travels unchanged through outer spans and
  -- through fork + join, and a failure that was caught and raised again is
  -- a new cause. Weak, so it holds nothing alive.
  local spanOfCause = setmetatable({}, { __mode = 'k' })

  function noteFailure(span, cause)
    if Fx.Cause.isInterruptedOnly(cause) then return end
    -- spans close inside out: the first to see a cause is the innermost
    if spanOfCause[cause] == nil then spanOfCause[cause] = span end
  end

  ---The innermost span that failed with cause (or a cause inside it), or nil.
  function trace.failedSpanOf(cause)
    local found = spanOfCause[cause]
    if found or type(cause) ~= 'table' then return found end
    Fx.Cause.walk(cause, function(node)
      if not found then found = spanOfCause[node] end
    end)
    return found
  end

  -- Effects -----------------------------------------------------------------

  ---Run self inside a new span, the child of the current one.
  ---opts.attributes: table; opts.kind: 'internal' (default), 'server',
  ---'client', 'producer', 'consumer'; opts.parent: a span or a traceparent
  ---string to continue (instead of the current span); opts.root = true to
  ---start a new trace.
  function Effect:withSpan(name, opts)
    local eff = self
    return Fx.suspend(function()
      if not enabled then return eff end
      -- The exit frame is in place before the span starts, so an interruption
      -- at any point either finds no span or finishes it.
      local span
      return Fx._onExitSync(Fx.withFiber(function(fiber)
        local parent
        if opts and opts.parent then
          parent = opts.parent
          if type(parent) == 'string' then parent = trace.parseTraceparent(parent) end
        elseif not (opts and opts.root) then
          parent = fiber.context[CurrentSpan]
        end
        span = trace.start(name, parent, opts)
        return eff:provideService(CurrentSpan, span)
      end), function(exit)
        if not span then return end
        trace.finish(span, exit)
        if exit._tag == 'Failure' then noteFailure(span, exit.cause) end
      end)
    end)
  end

  ---Wrap a function so each call runs in a span: Fx.span('name', fn)(...)
  ---returns fn(...)'s effect inside the span.
  function Fx.span(name, fn, opts)
    return function(...)
      local args = table.pack(...)
      return Fx.suspend(function() return fn(table.unpack(args, 1, args.n)) end):withSpan(name, opts)
    end
  end

  ---The current span, or nil.
  Fx.currentSpan = Fx.withFiber(function(fiber) return Fx.succeed(fiber.context[CurrentSpan]) end)

  ---Set an attribute on the current span (no-op without one).
  function Fx.annotateCurrentSpan(key, value)
    return Fx.withFiber(function(fiber)
      local span = fiber.context[CurrentSpan]
      if span then span.attributes[key] = value end
      return Fx.unit
    end)
  end

  ---The traceparent of the span a fiber runs in, or nil.
  function trace.traceparentOf(fiber)
    local span = fiber and fiber.context[CurrentSpan]
    return span and span:traceparent() or nil
  end
end
