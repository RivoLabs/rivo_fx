local T = ...
local test, eq, ok = T.test, T.eq, T.ok

local function check(schema, input)
  return table.pack(schema:validate(input))
end

test('primitives', function()
  local Fx = T.fresh()
  local S = Fx.S
  eq(check(S.string, 'a'), { true, 'a', n = 2 })
  eq(check(S.string, 1), { false, 'expected string, got 1', n = 2 })
  ok(S.number:is(1.5))
  ok(not S.number:is(0 / 0), 'NaN rejected')
  ok(not S.number:is(math.huge), 'inf rejected')
  eq(select(2, S.int:validate(3.0)), 3)
  ok(math.type(select(2, S.int:validate(3.0))) == 'integer')
  ok(not S.int:is(1.5))
  ok(S.boolean:is(false))
  ok(S.unknown:is(nil))
end)

test('refinements', function()
  local Fx = T.fresh()
  local S = Fx.S
  local amount = S.int:between(1, 100)
  ok(amount:is(50))
  eq(select(2, amount:validate(500)), 'must be between 1 and 100')
  ok(not S.string:maxLen(3):is('abcd'))
  ok(S.string:pattern('^%a+$'):is('abc'))
  ok(not S.string:pattern('^%a+$'):is('ab1'))
  ok(not S.number:positive():is(0))
  ok(S.string:nonEmpty():is('x'))
  ok(not S.array(S.int):maxItems(2):is({ 1, 2, 3 }))
end)

test('struct strips unknown keys, reports paths, applies defaults', function()
  local Fx = T.fresh()
  local S = Fx.S
  local Deposit = S.struct {
    amount = S.int:between(1, 1000),
    note = S.string:maxLen(10):optional(),
    account = S.enum { 'cash', 'bank' }:default('bank'),
    items = S.array(S.struct { id = S.int }):optional(),
  }
  local okv, v = Deposit:validate({ amount = 5, extra = 'evil' })
  ok(okv)
  eq(v, { amount = 5, account = 'bank' })
  eq(select(2, Deposit:validate({ amount = 5, items = { { id = 1 }, { id = 'x' } } })),
    'items[2].id: expected integer, got "x"')
  eq(select(2, Deposit:validate({ amount = 0 })), 'amount: must be between 1 and 1000')
  eq(select(2, Deposit:validate('nope')), 'expected object, got "nope"')
  eq(select(2, S.struct({ a = S.int }, { extra = 'error' }):validate({ a = 1, b = 2 })), 'b: unexpected field')
end)

test('array rejects non-sequences', function()
  local Fx = T.fresh()
  local S = Fx.S
  ok(S.array(S.int):is({}))
  ok(not S.array(S.int):is({ 1, 2, x = 3 }))
  ok(not S.array(S.int):is({ [1] = 1, [3] = 3 }))
end)

test('union, literal, tuple, record, tagged, lazy', function()
  local Fx = T.fresh()
  local S = Fx.S
  local u = S.union(S.int, S.string)
  ok(u:is(1) and u:is('a') and not u:is(true))
  ok(S.literal('a', 'b'):is('b'))
  ok(S.tuple(S.int, S.string):is({ 1, 'a' }))
  ok(not S.tuple(S.int, S.string):is({ 1, 'a', 3 }))
  ok(S.record(S.string, S.int):is({ a = 1, b = 2 }))
  ok(not S.record(S.string, S.int):is({ a = 'x' }))
  local Pay = S.tagged('type', {
    cash = S.struct { amount = S.int },
    card = S.struct { last4 = S.string:len(4) },
  })
  eq(select(2, Pay:validate({ type = 'cash', amount = 3 })), { type = 'cash', amount = 3 })
  eq(select(2, Pay:validate({ type = 'crypto' })), 'type: unknown variant "crypto"')
  local Node
  Node = S.struct { value = S.int, children = S.array(S.lazy(function() return Node end)):optional() }
  ok(Node:is({ value = 1, children = { { value = 2 } } }))
  ok(not Node:is({ value = 1, children = { { value = 'x' } } }))
end)

test('vectors accept tables and output plain tables outside FiveM', function()
  local Fx = T.fresh()
  local S = Fx.S
  eq(select(2, S.vector3:validate({ 1, 2, 3 })), { x = 1, y = 2, z = 3 })
  eq(select(2, S.vector3:validate({ x = 1, y = 2, z = 3 })), { x = 1, y = 2, z = 3 })
  eq(select(2, S.vector3:validate({ x = 1, y = 2 })), 'z: expected number, got nil')
end)

test('decode is an effect that fails with ParseError', function()
  local Fx, p = T.fresh()
  local exit = T.runExit(Fx, p, Fx.S.int:decode('x'))
  local e = Fx.Cause.failureOption(exit.cause)
  eq(e._tag, 'ParseError')
  eq(e.message, 'expected integer, got "x"')
  eq(T.run(Fx, p, Fx.S.int:decode(4)), 4)
  local okCall, err = pcall(function() return Fx.S.int:parse('x') end)
  ok(not okCall)
  eq(err._tag, 'ParseError')
end)

test('transform and TaggedError field schemas', function()
  local Fx = T.fresh()
  local S = Fx.S
  eq(select(2, S.string:transform(string.upper):validate('ab')), 'AB')
  local Err = Fx.TaggedError('NotEnough', { need = S.int })
  eq(Err { need = 3 }.need, 3)
  local okCall = pcall(function() return Err { need = 'x' } end)
  ok(not okCall)
end)

test('minChars and maxChars count characters, not bytes', function()
  local Fx = T.fresh()
  local name = Fx.S.string:minChars(2):maxChars(3)
  ok(name:is('héé'))       -- 3 characters, 5 bytes
  ok(not name:is('h'))
  ok(not name:is('héllo'))
  ok(not Fx.S.string:maxChars(10):is('\xff\xfe')) -- invalid UTF-8
  ok(Fx.S.string:maxLen(3):is('héé') == false) -- byte length, for contrast
end)
