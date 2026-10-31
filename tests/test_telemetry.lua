local T = ...
local test, eq, ok, match = T.test, T.eq, T.ok, T.match

local function spans(Fx)
  local list = {}
  Fx.trace.on(function(s) list[#list + 1] = s end)
  return list
end

test('withSpan records name, timing, status and nesting', function()
  local Fx, p = T.fresh()
  local got = spans(Fx)
  T.run(Fx, p, Fx.sleep(30):withSpan('inner', { attributes = { k = 'v' } })
    :zipRight(Fx.sleep(20)):withSpan('outer'))
  eq(#got, 2)
  local inner, outer = got[1], got[2]
  eq(inner.name, 'inner')
  eq(outer.name, 'outer')
  eq(inner.traceId, outer.traceId)
  eq(inner.parentSpanId, outer.spanId)
  eq(outer.parentSpanId, nil)
  eq(inner.endTime - inner.startTime, 30)
  eq(outer.endTime - outer.startTime, 50)
  eq(inner.status, 'ok')
  eq(inner.attributes.k, 'v')
  match(outer.traceId, '^%x+$')
  eq(#outer.traceId, 32)
  eq(#outer.spanId, 16)
end)

test('failures, defects and interruptions set the status', function()
  local Fx, p = T.fresh()
  local got = spans(Fx)
  local Broke = Fx.TaggedError('Broke')
  T.runExit(Fx, p, Broke {}:fail():withSpan('tagged'))
  T.runExit(Fx, p, Fx.die('kaput'):withSpan('defect'))
  T.runExit(Fx, p, Fx.never:withSpan('interrupted'):timeout(10))
  eq(got[1].status, 'error')
  eq(got[1].message, 'Broke')
  eq(got[1].attributes['fx.error'], 'Broke')
  eq(got[2].status, 'error')
  eq(got[2].attributes['fx.error'], 'defect')
  match(got[2].message, 'kaput')
  eq(got[3].status, 'unset')
  eq(got[3].attributes['fx.interrupted'], true)
end)

test('forked fibers inherit the span; root starts a new trace', function()
  local Fx, p = T.fresh()
  local got = spans(Fx)
  T.run(Fx, p, Fx.gen(function()
    local f = Fx.yield(Fx.unit:withSpan('child'):fork())
    Fx.yield(f:join())
    Fx.yield(Fx.unit:withSpan('elsewhere', { root = true }))
  end):withSpan('parent'))
  local byName = {}
  for _, s in ipairs(got) do byName[s.name] = s end
  eq(byName.child.parentSpanId, byName.parent.spanId)
  eq(byName.child.traceId, byName.parent.traceId)
  ok(byName.elsewhere.traceId ~= byName.parent.traceId)
  eq(byName.elsewhere.parentSpanId, nil)
end)

test('traceparent round trip and continuing a remote parent', function()
  local Fx, p = T.fresh()
  local got = spans(Fx)
  local tp = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
  eq(Fx.trace.parseTraceparent(tp), { traceId = '0af7651916cd43dd8448eb211c80319c', spanId = 'b7ad6b7169203331', remote = true })
  eq(Fx.trace.parseTraceparent('00-' .. ('0'):rep(32) .. '-b7ad6b7169203331-01'), nil)
  eq(Fx.trace.parseTraceparent('garbage'), nil)
  eq(Fx.trace.parseTraceparent('ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'), nil)
  local seen = T.run(Fx, p, Fx.currentSpan:map(function(s) return s:traceparent() end):withSpan('server', { parent = tp }))
  eq(got[1].traceId, '0af7651916cd43dd8448eb211c80319c')
  eq(got[1].parentSpanId, 'b7ad6b7169203331')
  match(seen, '^00%-0af7651916cd43dd8448eb211c80319c%-%x+%-01$')
  -- a bad traceparent starts a new trace instead of failing
  T.run(Fx, p, Fx.unit:withSpan('bad', { parent = 'nope' }))
  eq(got[2].parentSpanId, nil)
end)

test('Fx.span, annotateCurrentSpan, recent and setEnabled', function()
  local Fx, p = T.fresh()
  local got = spans(Fx)
  local deposit = Fx.span('bank.deposit', function(n)
    return Fx.annotateCurrentSpan('amount', n):as(n * 2)
  end)
  eq(T.run(Fx, p, deposit(21)), 42)
  eq(got[1].attributes.amount, 21)
  eq(#Fx.trace.recent(), 1)
  for _ = 1, 250 do T.run(Fx, p, Fx.unit:withSpan('x')) end
  eq(#Fx.trace.recent(), 200, 'ring buffer keeps the last 200')
  Fx.trace.setEnabled(false)
  local before = #got
  eq(T.run(Fx, p, Fx.succeed(1):withSpan('off')), 1)
  eq(#got, before)
end)

test('effect logs carry the trace and span ids', function()
  local Fx, p = T.fresh()
  local records = {}
  Fx.log.setSink(function(level, msg, fields) records[#records + 1] = fields end)
  local got = spans(Fx)
  T.run(Fx, p, Fx.logInfo('hello'):withSpan('logged'))
  eq(records[1].traceId, got[1].traceId)
  eq(records[1].spanId, got[1].spanId)
  T.run(Fx, p, Fx.logInfo('no span'))
  eq(records[2].traceId, nil)
end)

test('counters, gauges and label sets', function()
  local Fx = T.fresh()
  local c = Fx.metrics.counter('test_hits_total', { help = 'Hits' })
  c:inc()
  c:inc(2, { route = 'a' })
  c:inc(1, { route = 'a' })
  eq(c:value(), 1)
  eq(c:value({ route = 'a' }), 3)
  ok(not pcall(c.inc, c, -1), 'counters cannot go down')
  eq(Fx.metrics.counter('test_hits_total'), c, 'same name, same metric')
  ok(not pcall(Fx.metrics.gauge, 'test_hits_total'), 'a name keeps its kind')
  ok(not pcall(Fx.metrics.counter, 'bad name'), 'names are checked')
  local g = Fx.metrics.gauge('test_queue')
  g:set(5)
  g:add(-2)
  eq(g:value(), 3)
end)

test('histograms bucket observations; trackDuration and trackErrors', function()
  local Fx, p = T.fresh()
  local h = Fx.metrics.histogram('test_ms', { buckets = { 10, 100 } })
  local errors = Fx.metrics.counter('test_errors_total')
  local Broke = Fx.TaggedError('Broke')
  T.run(Fx, p, Fx.sleep(5):trackDuration(h))
  T.run(Fx, p, Fx.sleep(50):trackDuration(h))
  T.runExit(Fx, p, Broke {}:fail():delay(500):trackDuration(h):trackErrors(errors, { op = 'x' }))
  T.runExit(Fx, p, Fx.die('x'):trackErrors(errors))
  T.runExit(Fx, p, Fx.never:trackErrors(errors):timeout(5))
  local snap
  for _, m in ipairs(Fx.metrics.snapshot()) do if m.name == 'test_ms' then snap = m end end
  eq(snap.series[1].counts, { 1, 1, 1 })
  eq(snap.series[1].count, 3)
  eq(snap.series[1].sum, 555)
  eq(errors:value({ error = 'Broke', op = 'x' }), 1)
  eq(errors:value({ error = 'defect' }), 1)
end)

test('too many label sets are dropped, not stored', function()
  local Fx = T.fresh()
  Fx.log.setSink(function() end)
  local c = Fx.metrics.counter('test_by_player_total')
  for i = 1, 1200 do c:inc(1, { player = i }) end
  local n
  for _, m in ipairs(Fx.metrics.snapshot()) do if m.name == 'test_by_player_total' then n = #m.series end end
  eq(n, 1000)
end)

test('prometheus text format', function()
  local Fx, p = T.fresh()
  local c = Fx.metrics.counter('test_req_total', { help = 'Requests\nmade' })
  c:inc(3, { path = 'a"b\\c' })
  local h = Fx.metrics.histogram('test_lat_ms', { buckets = { 10, 100 } })
  h:observe(5)
  h:observe(50)
  h:observe(500)
  local text = Fx.metrics.prometheus({ resource = 'bank' })
  local function has(line) ok(text:find(line, 1, true), 'missing: ' .. line .. '\n' .. text) end
  has('# HELP test_req_total Requests\\nmade')
  has('# TYPE test_req_total counter')
  has('test_req_total{path="a\\"b\\\\c",resource="bank"} 3')
  has('# TYPE test_lat_ms histogram')
  has('test_lat_ms_bucket{resource="bank",le="10"} 1')
  has('test_lat_ms_bucket{resource="bank",le="100"} 2')
  has('test_lat_ms_bucket{resource="bank",le="+Inf"} 3')
  has('test_lat_ms_sum{resource="bank"} 555')
  has('test_lat_ms_count{resource="bank"} 3')
  has('# TYPE rivo_fx_fibers gauge')
end)

test('a raising exit hook keeps an interruption an interruption', function()
  local Fx, p = T.fresh()
  local h = Fx.metrics.histogram('test_hook_ms')
  Fx.log.setSink(function() end)
  local caught = false
  local fiber = Fx.runFork(Fx.never:trackDuration(h, { ['bad-label'] = 'x' })
    :catchAllCause(function() caught = true return Fx.unit end))
  p.run(10)
  fiber:interruptAsFork(0)
  p.run()
  ok(not caught, 'the catch did not run during the interruption')
  ok(fiber.exit._tag == 'Failure' and Fx.Cause.isInterrupted(fiber.exit.cause))
  ok(#Fx.Cause.defects(fiber.exit.cause) == 1, 'the hook error is kept next to the interruption')
end)

test('label values cannot imitate another label set', function()
  local Fx = T.fresh()
  local c = Fx.metrics.counter('test_collide_total')
  c:inc(1, { a = 'x\1b\0y' })
  c:inc(5, { a = 'x', b = 'y' })
  eq(c:value({ a = 'x\1b\0y' }), 1)
  eq(c:value({ a = 'x', b = 'y' }), 5)
end)

test('only declared error tags become label values', function()
  local Fx, p = T.fresh()
  local errors = Fx.metrics.counter('test_tags_total')
  local Mine = Fx.TaggedError('Mine')
  T.runExit(Fx, p, Mine {}:fail():trackErrors(errors))
  -- an error rebuilt from a wire table, with a tag nobody declared
  T.runExit(Fx, p, Fx.fail(Fx.taggedFromTable({ _tag = ('x'):rep(500) })):trackErrors(errors))
  eq(errors:value({ error = 'Mine' }), 1)
  eq(errors:value({ error = 'error' }), 1)
end)

test('a gauge without a number does not break rendering', function()
  local Fx = T.fresh()
  Fx.metrics.gauge('test_odd', { collect = function() return { { labels = { a = 'x' } }, { { a = 'y' }, 2 } } end })
  local text = Fx.metrics.prometheus()
  ok(text:find('test_odd{a="y"} 2', 1, true))
  ok(not text:find('a="x"', 1, true))
  local g = Fx.metrics.gauge('test_set')
  ok(not pcall(g.set, g, nil), 'set refuses a non-number')
end)

test('an interruption before the span starts leaves no open span', function()
  local Fx, p = T.fresh()
  local started, finished = 0, 0
  local realStart = Fx.trace.start
  Fx.trace.start = function(...) started = started + 1 return realStart(...) end
  Fx.trace.on(function() finished = finished + 1 end)
  -- interrupt at many different points of a long chain ending in a span
  -- The runner yields every 2048 steps; the interrupt lands at that yield,
  -- which some chain length puts between the span's start and its exit frame.
  for k = 1000, 1100 do
    local chain = Fx.unit
    for _ = 1, k do chain = chain:flatMap(function() return Fx.unit end) end
    local fiber = Fx.runFork(chain:zipRight(Fx.sleep(5):withSpan('work')))
    p.setTimeout(0, function() fiber:interruptAsFork(0) end)
    p.run()
  end
  ok(started > 0, 'some runs got as far as the span')
  eq(started, finished)
end)

test('devtools: live fibers, parents first, with status, age and span', function()
  local Fx, p = T.fresh()
  local tel = Fx._telemetry
  local child
  local root = Fx.runFork(Fx.gen(function()
    child = Fx.yield(Fx.never:withSpan('waiting child'):fork())
    Fx.yield(Fx.never)
  end):withSpan('root work'))
  local other = Fx.runFork(Fx.never)
  T.run(Fx, p, Fx.sleep(30))
  local r = tel.read('fibers')
  eq(r.total, 3)
  eq(#r.list, 3)
  local byId = {}
  for i, f in ipairs(r.list) do byId[f.id] = f f.pos = i end
  eq(byId[root.id].parent, nil)
  eq(byId[child.id].parent, root.id)
  ok(byId[child.id].pos == byId[root.id].pos + 1, 'a child comes right after its parent')
  eq(byId[root.id].children, 1)
  eq(byId[root.id].status, 'waiting')
  eq(byId[root.id].span, 'root work')
  eq(byId[child.id].span, 'waiting child')
  eq(byId[child.id].traceId, byId[root.id].traceId)
  eq(byId[root.id].age, 30)
  eq(byId[other.id].span, nil)
  -- limits are kept, and the total still counts everything
  local small = tel.read('fibers', { limit = 1 })
  eq(#small.list, 1)
  eq(small.total, 3)
  root:interruptAsFork(0)
  other:interruptAsFork(0)
  p.run()
  eq(tel.read('fibers').total, 0)
end)

test('devtools: failures from error logs, unhandled fibers and defects, read after a cursor', function()
  local Fx, p = T.fresh()
  local tel = Fx._telemetry
  Fx.log.setSink(function() end)
  Fx.log.setLevel('none') -- recorded even when not printed
  Fx.log.error('db down', { query = 'SELECT 1' })
  Fx.runFork(Fx.die('kaput'):withSpan('doomed'))
  p.run()
  local r = tel.read('failures')
  eq(#r.items, 2)
  eq(r.items[1].message, 'db down')
  eq(r.items[1].fields.query, 'SELECT 1')
  match(r.items[2].message, '^Unhandled failure in fiber #%d+')
  match(r.items[2].cause, 'kaput')
  ok(r.items[2].fiber, 'the fiber id is kept')
  eq(#r.items[2].traceId, 32)
  local spans = tel.read('spans').items
  eq(r.items[2].traceId, spans[#spans].traceId)
  -- only newer ones after a cursor from this run; everything with another epoch
  local after = tel.read('failures', { epoch = r.epoch, after = r.items[1].seq })
  eq(#after.items, 1)
  eq(#tel.read('failures', { epoch = 'other', after = 99 }).items, 2)
  -- the ring keeps the last 50
  for i = 1, 60 do Fx.log.error('e' .. i) end
  local all = tel.read('failures').items
  eq(#all, 50)
  eq(all[50].message, 'e60')
end)

test('devtools: spans read after a cursor, as plain data', function()
  local Fx, p = T.fresh()
  local tel = Fx._telemetry
  T.run(Fx, p, Fx.unit:withSpan('one', { attributes = { fn = print, nested = { deep = { deeper = { x = 1 } } }, nan = 0 / 0 } }))
  local r = tel.read('spans')
  eq(#r.items, 1)
  local s = r.items[1]
  eq(s.name, 'one')
  eq(type(s.attributes.fn), 'string', 'functions become strings')
  eq(s.attributes.nan, tostring(0 / 0))
  eq(s.attributes.nested.deep.deeper, tostring(s.attributes.nested.deep.deeper), 'depth is capped')
  T.run(Fx, p, Fx.unit:withSpan('two'))
  local newer = tel.read('spans', { epoch = r.epoch, after = s.seq })
  eq(#newer.items, 1)
  eq(newer.items[1].name, 'two')
  local summary = tel.read('summary')
  eq(summary.spans, 2)
  eq(summary.live, 0)
  eq(summary.failures, 0)
  eq(summary.tracing, true)
  eq(tel.read('nope'), nil)
end)

test('devtools: an unhandled failure links the innermost span that raised it, not an old one', function()
  local Fx, p = T.fresh()
  local tel = Fx._telemetry
  Fx.log.setSink(function() end)
  local got = spans(Fx)
  Fx.runFork(Fx.gen(function()
    -- fails in a span and is handled
    Fx.yield(Fx.fail('handled'):withSpan('recovered'):catchAll(function() return Fx.unit end))
    Fx.yield(Fx.die('inner boom'):withSpan('inner'):withSpan('outer'))
  end))
  Fx.runFork(Fx.gen(function()
    Fx.yield(Fx.fail('handled'):withSpan('recovered 2'):catchAll(function() return Fx.unit end))
    Fx.yield(Fx.die('no span'))
  end))
  p.run()
  local byName = {}
  for _, s in ipairs(got) do byName[s.name] = s end
  local f = tel.read('failures').items
  eq(#f, 2)
  eq(f[1].spanId, byName.inner.spanId)
  eq(f[2].traceId, nil, 'a failure outside any span links no trace')
end)

test('devtools: span links follow the failure itself, across fork + join, not its message', function()
  local Fx, p = T.fresh()
  local tel = Fx._telemetry
  Fx.log.setSink(function() end)
  local got = spans(Fx)
  -- the same message, caught once in a span, then raised again outside any span
  Fx.runFork(Fx.gen(function()
    Fx.yield(Fx.fail('timeout'):withSpan('old'):catchAll(function() return Fx.unit end))
    Fx.yield(Fx.fail('timeout'))
  end))
  -- and inside another span
  Fx.runFork(Fx.gen(function()
    Fx.yield(Fx.fail('timeout'):withSpan('A'):catchAll(function() return Fx.unit end))
    Fx.yield(Fx.fail('timeout'):withSpan('B'))
  end))
  -- a forked child fails in a span; its parent joins it and is the one that reports
  Fx.runFork(Fx.gen(function()
    local f = Fx.yield(Fx.fail('boom'):withSpan('child work'):fork())
    Fx.yield(f:join())
  end))
  p.run()
  local byName = {}
  for _, s in ipairs(got) do byName[s.name] = s end
  local f = tel.read('failures').items
  eq(#f, 3)
  eq(f[1].spanId, nil, 'not linked to the recovered span')
  eq(f[2].spanId, byName.B.spanId)
  eq(f[3].spanId, byName['child work'].spanId)
end)

test('devtools: odd values in metrics and log fields stay readable', function()
  local Fx = T.fresh()
  local tel = Fx._telemetry
  Fx.log.setSink(function() end)
  local g = Fx.metrics.gauge('test_odd_values')
  g:set(0 / 0, { k = 'nan' })
  g:set(math.huge, { k = 'inf' })
  local seen = {}
  for _, m in ipairs(tel.read('metrics')) do
    if m.name == 'test_odd_values' then for _, s in ipairs(m.series) do seen[s.labels.k] = s.value end end
  end
  eq(type(seen.nan), 'string')
  eq(seen.inf, tostring(math.huge))
  Fx.log.error('weird ids', { traceId = 12, spanId = { 'x' }, fiber = 'abc' })
  local item = tel.read('failures').items[1]
  eq(item.traceId, nil)
  eq(item.spanId, nil)
  eq(item.fiber, nil)
end)
