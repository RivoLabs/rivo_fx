# Observability

Rivo FX records spans around effects, keeps counters, gauges and histograms per resource, and writes levelled logs that carry the current trace. This page covers tracing (`eff:withSpan`, `Fx.span`, `Fx.trace.*`), metrics (`Fx.metrics.*`, `trackDuration`, `trackErrors`), logging (`Fx.log.*`, `Fx.logInfo` and friends), the spans and metrics the library records by itself, and the `rivo_fx` HTTP endpoint that serves them to Prometheus. Use it to find out where time goes, what failed and how often.

## Tracing

A span records a name, a start and end time (Unix ms), a status and attributes. The span an effect runs in is the parent of the spans it starts, including spans on fibers it forks. `Fx.rpc` carries the caller's span to the host as a W3C `traceparent`, so a client call and the server handler it reaches share one trace. Finished spans go to `Fx.trace.on` listeners, `Fx.trace.stream()`, and a ring buffer of the last 200 per resource (`Fx.trace.recent()`). Tracing is per resource and per side.

A finished span is a table:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | span name |
| `traceId` | string | 32 lowercase hex characters |
| `spanId` | string | 16 lowercase hex characters |
| `parentSpanId` | string? | parent span, `nil` for a root span |
| `kind` | string | `'internal'` (default), `'server'`, `'client'`, `'producer'` or `'consumer'` |
| `startTime`, `endTime` | integer | Unix ms |
| `status` | string | `'ok'`, `'error'` or `'unset'` |
| `message` | string? | on error: the error tag, the error as a string, or the first line of a defect (at most 256 characters, then `...`) |
| `attributes` | table | your attributes, plus `fx.error` and `fx.interrupted` (below) |
| `events` | table? | `{ name, time, attributes }` added with `span:addEvent` |
| `resource` | string | the resource that recorded it |
| `seq` | integer | order of finishing in this resource |

How an effect's outcome sets the status:

| Outcome | `status` | Extra |
|---|---|---|
| success | `'ok'` | |
| failure with a tagged error declared in this resource with `Fx.TaggedError` | `'error'` | `message` and `attributes['fx.error']` are the tag |
| failure with a tagged error rebuilt from the wire whose tag this resource never declared | `'error'` | `message` is the tag, `attributes['fx.error'] = 'error'` |
| failure with any other expected error | `'error'` | `message = tostring(err)`, no `fx.error` |
| defect | `'error'` | `attributes['fx.error'] = 'defect'` |
| interruption | `'unset'` | `attributes['fx.interrupted'] = true` |

### eff:withSpan(name, opts)

```lua
eff:withSpan(name: string, opts?: {
  attributes?: table<string, any>,
  kind?: 'internal'|'server'|'client'|'producer'|'consumer',
  parent?: Fx.Span|string,   -- a span or a W3C traceparent string
  root?: boolean,            -- start a new trace
}): Fx.Effect<A, E>
```

- **Parameters:** `name`, the span name; `opts.attributes`, copied onto the span; `opts.kind` (default `'internal'`); `opts.parent`, a span or traceparent string to continue instead of the current span; `opts.root = true` to start a new trace even inside another span.
- **Returns:** an effect that runs `eff` inside a new span and has the same result.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides. The span starts when the effect runs, not when `withSpan` is called, so each run makes a new span. A `parent` string that does not parse starts a new trace instead of failing. When tracing is off, `eff` runs unchanged. An interruption at any point either finds no span or finishes it; no span is left open.

```lua
local function deposit(src, amount)
  return Bank.credit(src, amount)
    :withSpan('bank.deposit', { attributes = { amount = amount, player = src } })
end
```

### Fx.span(name, fn, opts)

```lua
Fx.span(name: string, fn: fun(...): Fx.Effect<A, E>, opts?: Fx.SpanOptions): fun(...): Fx.Effect<A, E>
```

- **Parameters:** `name`, the span name; `fn`, a function that returns an effect; `opts`, as in `withSpan`.
- **Returns:** a function with the same arguments as `fn`. Each call returns `fn(...)`'s effect inside a span.
- **Fails with:** whatever `fn`'s effect fails with. A raising `fn` fails the effect.
- **Notes:** both sides. `fn` runs when the effect runs, not when the wrapper is called.

```lua
local deposit = Fx.span('bank.deposit', function(src, amount)
  return Fx.annotateCurrentSpan('amount', amount):zipRight(Bank.credit(src, amount))
end)

Fx.runFork(deposit(source, 500))
```

### Fx.currentSpan

```lua
Fx.currentSpan: Fx.Effect<Fx.Span|nil, never>
```

- **Returns:** an effect (a value, not a function) that succeeds with the span the fiber runs in, or `nil`.
- **Fails with:** never.
- **Notes:** both sides. Use it to add events or read ids.

```lua
local job = Fx.gen(function()
  local span = Fx.yield(Fx.currentSpan)
  if span then span:addEvent('cache miss', { key = 'garage:12' }) end
  return Fx.yield(Garage.load(12))
end):withSpan('garage.load')
```

### Fx.annotateCurrentSpan(key, value)

```lua
Fx.annotateCurrentSpan(key: string, value: any): Fx.Effect<nil, never>
```

- **Parameters:** `key`, the attribute name; `value`, its value.
- **Returns:** an effect that sets the attribute on the current span.
- **Fails with:** never.
- **Notes:** both sides. Does nothing outside a span.

```lua
Fx.rpc.register('shop:buy', { input = BuyInput }, function(src, input)
  return Fx.annotateCurrentSpan('item', input.item)
    :zipRight(Shop.buy(src, input.item, input.qty))
end)
```

### span:setAttribute(key, value)

```lua
span:setAttribute(key: string, value: any): Fx.Span
```

- **Parameters:** `key`, `value`.
- **Returns:** the span, for chaining.
- **Fails with:** never.
- **Notes:** both sides. Plain function on a span table from `Fx.currentSpan`, `Fx.trace.start` or a listener.

```lua
local span = Fx.trace.start('import vehicles')
span:setAttribute('rows', 120):setAttribute('source', 'csv')
Fx.trace.finish(span)
```

### span:addEvent(name, attributes)

```lua
span:addEvent(name: string, attributes?: table): Fx.Span
```

- **Parameters:** `name`, the event name; `attributes`, optional.
- **Returns:** the span.
- **Fails with:** never.
- **Notes:** both sides. Each event gets the current Unix ms time. At most 32 events per span; later ones are ignored.

```lua
Fx.yield(Fx.currentSpan):addEvent('model loaded', { model = 'adder' })
```

### span:traceparent()

```lua
span:traceparent(): string
```

- **Returns:** the W3C traceparent of the span: `00-<traceId>-<spanId>-01`.
- **Fails with:** never.
- **Notes:** both sides. Pass it to another system, or as `opts.parent` to continue the trace.

```lua
local tp = Fx.yield(Fx.currentSpan):traceparent()
PerformHttpRequest(url, cb, 'POST', body, { ['traceparent'] = tp })
```

### Fx.trace.on(fn)

```lua
Fx.trace.on(fn: fun(span: Fx.Span)): fun()
```

- **Parameters:** `fn`, called with each finished span of this resource.
- **Returns:** a function that removes the listener.
- **Fails with:** never. An error raised by `fn` is reported as a defect and does not reach the span's effect.
- **Notes:** both sides. Called synchronously when the span ends; keep it short.

```lua
local stop = Fx.trace.on(function(span)
  if span.status == 'error' then
    print(('span %s failed: %s'):format(span.name, span.message))
  end
end)
```

### Fx.trace.stream(opts)

```lua
Fx.trace.stream(opts?: { buffer?: integer }): Fx.Stream<Fx.Span>
```

- **Parameters:** `opts.buffer`, how many spans may wait for a slow consumer (default 1024; past that the oldest are dropped).
- **Returns:** a stream of spans finished after it starts. Never ends by itself.
- **Fails with:** never.
- **Notes:** both sides. See [Streams](streams.md).

```lua
-- server: ship slow spans to a log service in batches
Fx.runFork(Fx.trace.stream()
  :filter(function(s) return s.endTime - s.startTime > 250 end)
  :groupedWithin(50, 10000)
  :runForEach(function(batch) return LogShipper.send(batch) end))
```

### Fx.trace.recent(after)

```lua
Fx.trace.recent(after?: integer): Fx.Span[]
```

- **Parameters:** `after`, optional `seq`; only spans with a greater `seq` are returned.
- **Returns:** the most recent finished spans of this resource, oldest first, at most 200.
- **Fails with:** never.
- **Notes:** both sides. The buffer keeps the last 200 spans; older ones are overwritten.

```lua
local last = 0
RegisterCommand('slowspans', function()
  for _, s in ipairs(Fx.trace.recent(last)) do
    last = s.seq
    if s.endTime - s.startTime > 100 then print(s.name, s.endTime - s.startTime) end
  end
end, true)
```

### Fx.trace.start(name, parent, opts)

```lua
Fx.trace.start(name: string, parent?: Fx.Span|{ traceId: string, spanId: string }, opts?: {
  attributes?: table<string, any>,
  kind?: 'internal'|'server'|'client'|'producer'|'consumer',
}): Fx.Span
```

- **Parameters:** `name`; `parent`, a span or a parsed traceparent (from `Fx.trace.parseTraceparent`), or `nil` for a new trace; `opts.attributes` (copied) and `opts.kind`.
- **Returns:** a new open span with status `'unset'`.
- **Fails with:** never.
- **Notes:** both sides. A plain function, for code outside effects. End it with `Fx.trace.finish`. It is not the current span of any fiber. `parent` must be a table: a traceparent string is not parsed here and silently starts a new trace. Prefer `eff:withSpan`, which starts and finishes for you.

```lua
AddEventHandler('onResourceStart', function(res)
  local span = Fx.trace.start('resource start', nil, { attributes = { resource = res } })
  -- ... plain Lua work
  Fx.trace.finish(span)
end)
```

### Fx.trace.finish(span, exit)

```lua
Fx.trace.finish(span: Fx.Span, exit?: Fx.Exit)
```

- **Parameters:** `span`, from `Fx.trace.start`; `exit`, optional, sets the status from an effect's outcome (see the status table above).
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. Without `exit`, the status stays `'unset'`. Finishing a span twice does nothing the second time. The span then goes to listeners, `Fx.trace.stream()` and `Fx.trace.recent()`.

```lua
local span = Fx.trace.start('nightly cleanup')
Fx.runFork(Cleanup.run(), { onExit = function(exit) Fx.trace.finish(span, exit) end })
```

### Fx.trace.parseTraceparent(s)

```lua
Fx.trace.parseTraceparent(s: string): { traceId: string, spanId: string, remote: true }|nil
```

- **Parameters:** `s`, a W3C traceparent (`00-<32 hex>-<16 hex>-<2 hex>`, 55 characters).
- **Returns:** the ids (lowercased) with `remote = true`, or `nil` when `s` is not a string, has the wrong length or shape, uses version `ff`, or has an all-zero trace or span id.
- **Fails with:** never.
- **Notes:** both sides. The result works as `parent` for `Fx.trace.start`.

```lua
local parent = Fx.trace.parseTraceparent(headers['traceparent'])
local span = Fx.trace.start('webhook', parent, { kind = 'server' })
```

### Fx.trace.traceparentOf(fiber)

```lua
Fx.trace.traceparentOf(fiber: Fx.Fiber): string|nil
```

- **Parameters:** `fiber`.
- **Returns:** the traceparent of the span the fiber runs in, or `nil`.
- **Fails with:** never.
- **Notes:** both sides. `Fx.rpc` uses it to fill the request's `trace` field. A fiber from `Fx.runFork` has not run yet when `runFork` returns, so this gives `nil` until the fiber has entered its span.

```lua
local worker = Fx.runFork(Jobs.worker():withSpan('job worker'))

RegisterCommand('workertrace', function()
  print(Fx.trace.traceparentOf(worker))   -- 00-<traceId>-<spanId>-01
end, true)
```

### Fx.trace.failedSpanOf(cause)

```lua
Fx.trace.failedSpanOf(cause: Fx.Cause): Fx.Span|nil
```

- **Parameters:** `cause`, a failure cause.
- **Returns:** the innermost span that failed with this cause (or a cause inside it), or `nil`.
- **Fails with:** never.
- **Notes:** both sides. Used to link an unhandled fiber failure, reported after its spans have closed, to the span that raised it. Interruptions are not linked. A failure caught and raised again is a new cause.

```lua
Fx.runFork(Job.run(), { onExit = function(exit)
  if exit._tag == 'Failure' then
    local span = Fx.trace.failedSpanOf(exit.cause)
    Fx.log.error('job failed', { span = span and span.name, traceId = span and span.traceId })
  end
end })
```

### Fx.trace.setEnabled(on)

```lua
Fx.trace.setEnabled(on: boolean)
Fx.trace.isEnabled(): boolean
```

- **Parameters:** `on`, `true` to record spans, `false` to stop.
- **Returns:** nothing; `isEnabled()` returns the current setting.
- **Fails with:** never.
- **Notes:** both sides, per resource. Overrides the `rivo_fx:tracing` convar. While off, `withSpan` and `Fx.span` run the effect without a span (so `Fx.currentSpan` gives `nil` in new work) and RPC calls and handlers record no spans.

```lua
-- turn tracing off in a hot resource during an event
Fx.trace.setEnabled(false)
```

### Fx.trace.nowMs()

```lua
Fx.trace.nowMs(): integer
```

- **Returns:** Unix ms, from the platform clock anchored once to the wall clock (`os.time`, or `GetCloudTimeAsInt` on clients where `os.time` is not usable).
- **Fails with:** never.
- **Notes:** both sides. This is the clock span times use.

```lua
local t0 = Fx.trace.nowMs()
```

### Fx.trace.CurrentSpan

```lua
Fx.trace.CurrentSpan: Fx.Tag   -- 'rivo_fx/CurrentSpan'
```

- **Returns:** the service tag that holds the current span in a fiber's context.
- **Fails with:** never.
- **Notes:** both sides. `withSpan` provides it. Providing it yourself makes a span from `Fx.trace.start` the parent of spans inside an effect.

```lua
local span = Fx.trace.start('batch import')
Fx.runFork(Import.all():provideService(Fx.trace.CurrentSpan, span),
  { onExit = function(exit) Fx.trace.finish(span, exit) end })
```

### Trace propagation over Fx.rpc

- Every `Fx.rpc.call` / `Fx.rpc.callClient` runs in a span `rpc.client <name>` (kind `client`, attributes `rpc.name`, `rpc.target`, and `player` for `callClient`). It is a child of the caller's current span.
- The request carries that span's traceparent in its `trace` field.
- The host runs the handler in a span `rpc.server <name>` (kind `server`, attributes `rpc.name`, `rpc.caller`, and `player` on the server) whose parent is the caller's span. A `trace` that is missing, not a string, longer than 64 characters or malformed starts a new trace; the request is still answered.
- The Lua and JS implementations use the same field, so traces join across languages. See [Net events and RPC](net-rpc.md).

```lua
-- client: the 'open bank' span, the rpc.client span and the server's
-- rpc.server span all share one traceId
Fx.runFork(Fx.rpc.call('bank:balance', {}):withSpan('open bank'))
```

### Convar rivo_fx:tracing

```cfg
set rivo_fx:tracing off
```

- `off` (exactly) stops span recording in every resource that loads Rivo FX on that side; any other value, or unset, leaves it on.
- Read once, when the resource starts. `Fx.trace.setEnabled` overrides it at run time.
- Clients only see replicated convars, so use `setr rivo_fx:tracing off` to turn it off on clients too.

## Metrics

Metrics live per resource and per side. A metric name may be defined more than once in a resource: the same kind returns the existing metric (its first options are kept), a different kind raises.

Names must match `^[a-zA-Z_:][a-zA-Z0-9_:]*$`; label names must match `^[a-zA-Z_][a-zA-Z0-9_]*$` and label values are turned into strings. Each distinct label set is one series.

**Series limit.** A metric holds at most 1000 series. Updates that would create series number 1001 or later are dropped, and one warning is logged for that metric. This keeps a label a client controls (a player id, a payload field) from growing memory without bound. Avoid such labels anyway.

Metric methods do not check the metric's kind; call the ones listed for it.

### Fx.metrics.counter(name, opts)

```lua
Fx.metrics.counter(name: string, opts?: { help?: string }): Fx.Counter
```

- **Parameters:** `name`; `opts.help`, the description shown in Prometheus.
- **Returns:** a counter: a value that only goes up. Methods: `inc`, `value`, `update`.
- **Fails with:** never; raises on an invalid name or when `name` is already another kind.
- **Notes:** both sides.

```lua
local Deposits = Fx.metrics.counter('bank_deposits_total', { help = 'Deposits made' })
Deposits:inc(1, { account = 'main' })
```

### Fx.metrics.gauge(name, opts)

```lua
Fx.metrics.gauge(name: string, opts?: {
  help?: string,
  collect?: fun(): number | { { labels: table, value: number } | { [1]: table, [2]: number } },
}): Fx.Gauge
```

- **Parameters:** `name`; `opts.help`; `opts.collect`, a function that computes the gauge each time metrics are read, returning a number (one series without labels) or a list of `{ labels, value }` (or `{ labels = ..., value = ... }`) entries.
- **Returns:** a gauge: a value that goes up and down. Methods: `set`, `add`, `value`, `update`.
- **Fails with:** never; raises on an invalid name or kind clash.
- **Notes:** both sides. With `collect`, `set`/`add` values are not reported and `value()` returns 0; only `collect`'s result appears in `snapshot()`. Entries whose value is not a number are skipped. A raising `collect` is reported as a defect and the gauge reports no series.

```lua
Fx.metrics.gauge('garage_vehicles_out', {
  help = 'Vehicles spawned from garages, by garage',
  collect = function()
    local out = {}
    for name, g in pairs(Garages) do out[#out + 1] = { labels = { garage = name }, value = g.out } end
    return out
  end,
})
```

### Fx.metrics.histogram(name, opts)

```lua
Fx.metrics.histogram(name: string, opts?: { help?: string, buckets?: number[] }): Fx.Histogram
```

- **Parameters:** `name`; `opts.help`; `opts.buckets`, ascending upper bounds (default `{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 }`).
- **Returns:** a histogram: counts of observations per bucket, plus sum and count. Methods: `observe`, `update`.
- **Fails with:** never; raises on an invalid name, kind clash, or buckets that do not ascend.
- **Notes:** both sides. An observation `v` counts in the first bucket with `v <= bound`, or above every bucket. The default buckets suit milliseconds.

```lua
local Latency = Fx.metrics.histogram('bank_deposit_ms', { help = 'Deposit time', buckets = { 5, 25, 100, 500 } })
```

### counter:inc(n, labels)

```lua
counter:inc(n?: number, labels?: table<string, any>)
```

- **Parameters:** `n`, how much to add (default 1); `labels`, the series.
- **Returns:** nothing.
- **Fails with:** never; raises when `n` is negative or a label name is invalid.
- **Notes:** both sides. Plain function, runs at once.

```lua
Deposits:inc()                         -- no labels
Deposits:inc(2, { account = 'savings' })
```

### gauge:set(v, labels)

```lua
gauge:set(v: number, labels?: table<string, any>)
```

- **Parameters:** `v`, the value; `labels`, the series.
- **Returns:** nothing.
- **Fails with:** never; raises when `v` is not a number.
- **Notes:** both sides.

```lua
local Online = Fx.metrics.gauge('players_online')
AddEventHandler('playerJoining', function() Online:set(#GetPlayers()) end)
```

### gauge:add(n, labels)

```lua
gauge:add(n: number, labels?: table<string, any>)
```

- **Parameters:** `n`, may be negative; `labels`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides.

```lua
local InQueue = Fx.metrics.gauge('queue_players')
InQueue:add(1)    -- joined the queue
InQueue:add(-1)   -- left it
```

### histogram:observe(v, labels)

```lua
histogram:observe(v: number, labels?: table<string, any>)
```

- **Parameters:** `v`, one observation; `labels`.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. For timing effects use `eff:trackDuration`.

```lua
local Payouts = Fx.metrics.histogram('job_payout', { buckets = { 100, 500, 1000, 5000 } })
Payouts:observe(750, { job = 'trucker' })
```

### metric:value(labels)

```lua
counter:value(labels?: table<string, any>): number
gauge:value(labels?: table<string, any>): number
```

- **Parameters:** `labels`, the series.
- **Returns:** the current value of a counter or gauge series, 0 when it was never set.
- **Fails with:** never.
- **Notes:** both sides. Returns 0 for histograms and for gauges with `collect`; read those with `Fx.metrics.snapshot()`.

```lua
print(Deposits:value({ account = 'main' }))
```

### metric:update(v, labels)

```lua
counter:update(n?: number, labels?): Fx.Effect<nil, never>
gauge:update(v: number, labels?): Fx.Effect<nil, never>
histogram:update(v: number, labels?): Fx.Effect<nil, never>
```

- **Parameters:** as `inc` (counter), `set` (gauge) or `observe` (histogram).
- **Returns:** an effect that does the update when it runs.
- **Fails with:** never (invalid arguments raise when it runs, which is a defect).
- **Notes:** both sides. For use inside pipelines.

```lua
local Sold = Fx.metrics.counter('shop_items_sold_total')
local buy = Shop.buy(src, item):tap(function() return Sold:update(1, { item = item }) end)
```

### eff:trackDuration(histogram, labels)

```lua
eff:trackDuration(histogram: Fx.Histogram, labels?: table<string, any>): Fx.Effect<A, E>
```

- **Parameters:** `histogram`; `labels`, the series.
- **Returns:** an effect with the same result that observes how long `eff` took, in ms.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides. Observes every outcome: success, failure and interruption. Time comes from the platform clock.

```lua
local Latency = Fx.metrics.histogram('bank_deposit_ms', { buckets = { 5, 25, 100, 500 } })
local function deposit(src, amount)
  return Bank.credit(src, amount):trackDuration(Latency, { account = 'main' })
end
```

### eff:trackErrors(counter, labels)

```lua
eff:trackErrors(counter: Fx.Counter, labels?: table<string, any>): Fx.Effect<A, E>
```

- **Parameters:** `counter`; `labels`, extra labels added to every count.
- **Returns:** an effect with the same result that adds 1 to `counter` each time `eff` fails.
- **Fails with:** whatever `eff` fails with.
- **Notes:** both sides. Interruptions are not counted. The `error` label is the `_tag` of an error declared in this resource with `Fx.TaggedError`; `'error'` for any other tagged error (one rebuilt from another side, whose tag a client could make up); `'defect'` for defects; `'unknown'` for other failures. A label you pass named `error` replaces it.

```lua
local Failures = Fx.metrics.counter('bank_failures_total', { help = 'Failed bank operations' })
local function withdraw(src, amount)
  return Bank.withdraw(src, amount):trackErrors(Failures, { op = 'withdraw' })
end
-- after a NotEnoughMoney failure:
-- bank_failures_total{error="NotEnoughMoney",op="withdraw"} 1
```

### Fx.metrics.snapshot()

```lua
Fx.metrics.snapshot(): {
  name: string,
  kind: 'counter'|'gauge'|'histogram',
  help: string,
  buckets?: number[],
  series: ({ labels: table<string, string>, value: number }
         | { labels: table<string, string>, counts: integer[], sum: number, count: integer })[],
}[]
```

- **Returns:** every metric of this resource, in definition order, with copies of its series. Counter and gauge series have `value`. Histogram series have `counts` per bucket (not cumulative; the last entry counts observations above every bucket), `sum` and `count`.
- **Fails with:** never.
- **Notes:** both sides. Runs every gauge's `collect`. Includes the built-in metrics.

```lua
for _, m in ipairs(Fx.metrics.snapshot()) do
  if m.name == 'bank_deposit_ms' then
    for _, s in ipairs(m.series) do print(s.labels.account, s.count, s.sum / s.count) end
  end
end
```

### Fx.metrics.prometheus(extraLabels, snapshot)

```lua
Fx.metrics.prometheus(extraLabels?: table<string, string>, snapshot?: Fx.MetricSnapshot[]): string
```

- **Parameters:** `extraLabels`, added to every series that does not set them itself (for example `{ resource = 'bank' }`); `snapshot`, what to render (default `Fx.metrics.snapshot()`).
- **Returns:** the Prometheus text format (version 0.0.4), ending in a newline.
- **Fails with:** never.
- **Notes:** both sides. `# HELP` is written only when `help` is set. Labels are sorted by name; a histogram's `le` comes last. Histograms are rendered as cumulative `_bucket` lines plus `+Inf`, `_sum` and `_count`. NaN and infinities are rendered as `NaN`, `+Inf` and `-Inf`. On the server you normally scrape the [HTTP endpoint](#http-endpoint) instead.

```lua
print(Fx.metrics.prometheus({ resource = GetCurrentResourceName() }))
-- # HELP bank_deposits_total Deposits made
-- # TYPE bank_deposits_total counter
-- bank_deposits_total{account="main",resource="bank"} 3
```

## Logging

`Fx.log` writes levelled, structured log lines. The minimum level comes from the convar `rivo_fx:logLevel`: `debug`, `info` (default), `warn`, `error` or `none`, case-insensitive; an unknown value means `info`. It is read when the resource first uses `Fx.log`. On clients, use `setr` so the convar replicates. Each line is printed as `[LEVEL] message key=value ...` with colour codes, fields sorted by key; tables are inspected.

Error records reach the `/fxdev` devtools' Failures view whatever the level and sink.

### Fx.log.info(msg, fields)

```lua
Fx.log.debug(msg: string, fields?: table)
Fx.log.info(msg: string, fields?: table)
Fx.log.warn(msg: string, fields?: table)
Fx.log.error(msg: string, fields?: table)
```

- **Parameters:** `msg`, the message; `fields`, optional key/value pairs.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides. Plain functions that write at once. Records below the level are dropped. Inside effects prefer `Fx.logInfo` and friends, which add the fiber and trace ids.

```lua
Fx.log.info('garage opened', { src = source, garage = 'pillbox' })
-- [INFO] garage opened garage=pillbox src=3
Fx.log.error('db down', { query = 'SELECT 1' })
```

### Fx.log.setLevel(level)

```lua
Fx.log.setLevel(level: 'debug'|'info'|'warn'|'error'|'none')
Fx.log.getLevel(): string
```

- **Parameters:** `level`, case-insensitive.
- **Returns:** nothing; `getLevel()` returns the current level.
- **Fails with:** never; raises on an unknown level.
- **Notes:** both sides, per resource. Overrides the convar.

```lua
RegisterCommand('bankdebug', function() Fx.log.setLevel('debug') end, true)
```

### Fx.log.setSink(fn)

```lua
Fx.log.setSink(fn: (fun(level: string, msg: string, fields?: table))|nil)
```

- **Parameters:** `fn`, receives each record at or above the level instead of printing it; `nil` restores printing.
- **Returns:** nothing.
- **Fails with:** never.
- **Notes:** both sides, per resource. Also receives the library's own logs (rejected payloads, failed handlers).

```lua
Fx.log.setSink(function(level, msg, fields)
  if level == 'error' then exports.discord_logs:send(msg, json.encode(fields or {})) end
  print(('[%s] %s'):format(level, msg))
end)
```

### Fx.logInfo(msg, fields)

```lua
Fx.logDebug(msg: string, fields?: table): Fx.Effect<nil, never>
Fx.logInfo(msg: string, fields?: table): Fx.Effect<nil, never>
Fx.logWarn(msg: string, fields?: table): Fx.Effect<nil, never>
Fx.logError(msg: string, fields?: table): Fx.Effect<nil, never>
```

- **Parameters:** as `Fx.log.*`.
- **Returns:** an effect that writes the record when it runs.
- **Fails with:** never.
- **Notes:** both sides. Adds `fiber` (the fiber id) and, inside a span, `traceId` and `spanId`, so a log line leads to its trace. Your `fields` are merged on top.

```lua
Fx.rpc.register('garage:take', { input = TakeInput }, function(src, input)
  return Fx.gen(function()
    Fx.yield(Fx.logInfo('taking vehicle', { src = src, plate = input.plate }))
    return Fx.yield(Garage.take(src, input.plate))
  end)
end)
-- [INFO] taking vehicle fiber=12 plate=RIVO001 spanId=... src=3 traceId=...
```

## Built-in spans and metrics

Spans:

| Span | Kind | Where | Attributes |
|---|---|---|---|
| `rpc.client <name>` | `client` | caller of `Fx.rpc.call` / `callClient` | `rpc.name`, `rpc.target`, `player` (`callClient`) |
| `rpc.server <name>` | `server` | RPC host, child of the caller's span | `rpc.name`, `rpc.caller`, `player` (server) |
| `net <name>` | `server` | `Fx.net.handle`, only when the handler returns an effect (both sides) | `net.event`, `player` (server) |

Metrics. Each is defined when its module is first used in the resource:

| Metric | Kind | Labels | Meaning |
|---|---|---|---|
| `rivo_fx_rpc_handler_ms` | histogram | `name`, `outcome` | RPC handler time on the host |
| `rivo_fx_rpc_call_ms` | histogram | `name`, `outcome` | RPC round trip seen by the caller |
| `rivo_fx_net_events_total` | counter | `name` | net events that passed their checks (`Fx.net.handle`, `Fx.net.stream`) |
| `rivo_fx_security_events_total` | counter | `kind` | rejected client input ([security events](net-rpc.md#fxsecurity)) |
| `rivo_fx_fibers` | gauge | | root fibers alive in this resource |
| `rivo_fx_timers` | gauge | | timers waiting in the fiber runner |

`outcome` is `ok`, `interrupted`, the error tag when this resource declared it (the `Rpc*` tags count), `error` for any other tagged error, or `defect`.

## HTTP endpoint

The `rivo_fx` resource serves the metrics and recent spans of every server-side resource that uses Rivo FX, over the server's HTTP port:

| Request | Response |
|---|---|
| `GET /rivo_fx/metrics` | Prometheus text format (`text/plain; version=0.0.4`). Every resource's metrics merged, each series labelled `resource="<name>"` unless it sets `resource` itself. |
| `GET /rivo_fx/spans?limit=N` | JSON array of recent spans across resources, newest first. `limit` defaults to 100, at most 1000. Each resource contributes its last 200. |

- Off until the server convar `rivo_fx:metricsToken` is set; until then every request gets `404`. Set it with `set`, not `setr`, so it never reaches clients. It is read on each request.
- Requests must send `Authorization: Bearer <token>`; otherwise `401` with `WWW-Authenticate: Bearer`. The comparison is constant time.
- Methods other than `GET` get `405`; other paths `404`; an internal error `500`.
- When two resources define a metric with different kinds (or different histogram buckets), the first resource's definition is kept and the other's series are skipped.
- Client metrics and spans are not served here; see them in `/fxdev`.
- Span JSON fields: `seq`, `name`, `traceId`, `spanId`, `parentSpanId`, `kind`, `startTime`, `endTime`, `status`, `message`, `attributes`, `events`, `resource`, `side`. Attribute values are reduced to plain data (functions become strings, depth and size are capped).

```cfg
# server.cfg
ensure rivo_fx
set rivo_fx:metricsToken "a-long-random-string"   # set, not setr: keep it off clients
```

```yaml
# prometheus.yml
scrape_configs:
  - job_name: fivem
    metrics_path: /rivo_fx/metrics
    authorization: { credentials: a-long-random-string }
    static_configs: [{ targets: ['your-server:30120'] }]
```

```sh
curl -H 'Authorization: Bearer a-long-random-string' 'http://your-server:30120/rivo_fx/spans?limit=20'
```

## Convars

| Convar | Values | Default | Read |
|---|---|---|---|
| `rivo_fx:tracing` | `off` to stop recording spans | on | at resource start; `Fx.trace.setEnabled` overrides |
| `rivo_fx:logLevel` | `debug`, `info`, `warn`, `error`, `none` | `info` | on first use of `Fx.log`; `Fx.log.setLevel` overrides |
| `rivo_fx:metricsToken` | bearer token for the HTTP endpoint (server, `set` only) | unset: endpoint off | on every request |
