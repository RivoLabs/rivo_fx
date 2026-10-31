-- Schema: runtime validation for anything that crosses a trust boundary
-- (net events, RPC input, convars, config files, KVP).
--
--   local Deposit = Fx.S.struct {
--     amount = Fx.S.int:between(1, 1000000),
--     note = Fx.S.string:maxLen(64):optional(),
--   }
--   local ok, value = Deposit:validate(payload)
return function(Fx)
  local type, pairs, ipairs, tostring, setmetatable, math_type = type, pairs, ipairs, tostring, setmetatable, math.type

  local Schema = {}
  Schema.__index = Schema
  Schema.__name = 'Fx.Schema'

  local S = {}
  Fx.S = S
  Fx.Schema = S
  S._mt = Schema

  Fx.ParseError = Fx.TaggedError('ParseError')

  local function make(kind, check, extra)
    local s = setmetatable({ kind = kind, _check = check }, Schema)
    if extra then for k, v in pairs(extra) do s[k] = v end end
    return s
  end

  local function clone(s, overrides)
    local c = setmetatable({}, Schema)
    for k, v in pairs(s) do c[k] = v end
    for k, v in pairs(overrides) do c[k] = v end
    return c
  end

  local function join(path, key)
    if type(key) == 'number' then return (path or '') .. '[' .. key .. ']' end
    if path == nil or path == '' then return tostring(key) end
    return path .. '.' .. tostring(key)
  end

  local function describeValue(v)
    local t = type(v)
    if t == 'string' then
      if #v > 32 then return 'string of length ' .. #v end
      return string.format('%q', v)
    end
    if t == 'number' or t == 'boolean' or t == 'nil' then return tostring(v) end
    return t
  end

  local function issue(path, msg)
    if path and path ~= '' then return path .. ': ' .. msg end
    return msg
  end

  local function run(s, v, path)
    if v == nil then
      if s._default ~= nil then
        local d = s._default
        if type(d) == 'function' then d = d() end
        return true, d
      end
      if s._optional then return true, nil end
    end
    return s._check(v, path)
  end
  S._run = run

  -- Checking ------------------------------------------------------------------

  ---Check input. Returns true, value (with defaults and transforms applied)
  ---or false, message.
  ---@return boolean ok
  ---@return any valueOrMessage
  function Schema:validate(input) return run(self, input, '') end

  ---Effect that succeeds with the decoded value or fails with ParseError.
  ---@return Fx.Effect<any, table>
  function Schema:decode(input)
    local s = self
    return Fx.suspend(function()
      local ok, v = run(s, input, '')
      if ok then return Fx.succeed(v) end
      return Fx.fail(Fx.ParseError { message = v })
    end)
  end

  ---Return the decoded value or raise ParseError.
  function Schema:parse(input)
    local ok, v = run(self, input, '')
    if not ok then error(Fx.ParseError { message = v }, 2) end
    return v
  end

  function Schema:is(input) return (run(self, input, '')) end

  -- Modifiers -----------------------------------------------------------------

  ---Allow nil (a missing field).
  function Schema:optional() return clone(self, { _optional = true }) end

  ---Use v (or v() when a function) when the input is nil.
  function Schema:default(v) return clone(self, { _default = v }) end

  function Schema:describe(text) return clone(self, { description = text }) end

  ---Add a check. pred(value) returns true, or false and an optional message.
  function Schema:refine(pred, message)
    local inner = self._check
    return clone(self, {
      _check = function(v, path)
        local ok, out = inner(v, path)
        if not ok then return false, out end
        local good, msg = pred(out)
        if not good then return false, issue(path, msg or message or 'failed refinement') end
        return true, out
      end,
    })
  end

  ---Map the decoded value. fn may raise to reject.
  function Schema:transform(fn)
    local inner = self._check
    return clone(self, {
      _check = function(v, path)
        local ok, out = inner(v, path)
        if not ok then return false, out end
        local good, res = pcall(fn, out)
        if not good then return false, issue(path, tostring(res)) end
        return true, res
      end,
    })
  end

  local function sizeOf(v)
    local t = type(v)
    if t == 'string' then return #v end
    if t == 'table' then
      local n = 0
      for _ in pairs(v) do n = n + 1 end
      return n
    end
    return nil
  end

  function Schema:min(n)
    return self:refine(function(v) return v >= n end, 'must be >= ' .. n)
  end
  function Schema:max(n)
    return self:refine(function(v) return v <= n end, 'must be <= ' .. n)
  end
  function Schema:between(lo, hi)
    return self:refine(function(v) return v >= lo and v <= hi end, ('must be between %s and %s'):format(lo, hi))
  end
  function Schema:positive() return self:refine(function(v) return v > 0 end, 'must be positive') end
  function Schema:nonNegative() return self:refine(function(v) return v >= 0 end, 'must be >= 0') end

  function Schema:minLen(n)
    return self:refine(function(v) return sizeOf(v) >= n end, 'length must be >= ' .. n)
  end
  function Schema:maxLen(n)
    return self:refine(function(v) return sizeOf(v) <= n end, 'length must be <= ' .. n)
  end
  function Schema:len(n)
    return self:refine(function(v) return sizeOf(v) == n end, 'length must be ' .. n)
  end
  function Schema:nonEmpty() return self:minLen(1) end
  Schema.minItems = Schema.minLen
  Schema.maxItems = Schema.maxLen
  Schema.maxEntries = Schema.maxLen

  ---String length in characters (UTF-8 code points), not bytes. Invalid
  ---UTF-8 fails. JS counts the same way with isMinCodePoints/isMaxCodePoints.
  local function chars(v)
    if type(v) ~= 'string' then return nil end
    return utf8.len(v)
  end
  function Schema:minChars(n)
    return self:refine(function(v) local c = chars(v) return c ~= nil and c >= n end, 'must be at least ' .. n .. ' characters')
  end
  function Schema:maxChars(n)
    return self:refine(function(v) local c = chars(v) return c ~= nil and c <= n end, 'must be at most ' .. n .. ' characters')
  end

  ---Lua pattern match (anchor it yourself with ^ and $).
  function Schema:pattern(p, message)
    return self:refine(function(v) return v:find(p) ~= nil end, message or ('must match ' .. p))
  end

  -- Primitives ----------------------------------------------------------------

  local function typed(kind, luaType)
    return make(kind, function(v, path)
      if type(v) ~= luaType then
        return false, issue(path, 'expected ' .. kind .. ', got ' .. describeValue(v))
      end
      return true, v
    end)
  end

  S.string = typed('string', 'string')
  S.boolean = typed('boolean', 'boolean')

  ---Finite number (NaN and infinity are rejected).
  S.number = make('number', function(v, path)
    if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then
      return false, issue(path, 'expected number, got ' .. describeValue(v))
    end
    return true, v
  end)

  ---Integer (a float with no fraction is accepted and converted).
  S.int = make('int', function(v, path)
    if type(v) == 'number' then
      if math_type(v) == 'integer' then return true, v end
      local i = math.tointeger(v)
      if i then return true, i end
    end
    return false, issue(path, 'expected integer, got ' .. describeValue(v))
  end)
  S.integer = S.int

  ---Accepts anything (an explicit opt-out of validation).
  S.unknown = make('unknown', function(v) return true, v end)
  S.any = S.unknown

  ---Only nil.
  S['nil'] = make('nil', function(v, path)
    if v ~= nil then return false, issue(path, 'expected nil, got ' .. describeValue(v)) end
    return true, nil
  end)
  S['nil']._optional = true

  ---One of the given values (compared with ==).
  function S.literal(...)
    local values = { ... }
    local names = {}
    for i, v in ipairs(values) do names[i] = describeValue(v) end
    local expected = table.concat(names, ' | ')
    return make('literal', function(v, path)
      for _, x in ipairs(values) do if v == x then return true, v end end
      return false, issue(path, 'expected ' .. expected .. ', got ' .. describeValue(v))
    end, { values = values })
  end

  ---One of the strings in the list: S.enum { 'cash', 'bank' }
  function S.enum(list) return S.literal(table.unpack(list)) end

  -- Containers ----------------------------------------------------------------

  ---A sequence: every element matches item.
  function S.array(item)
    return make('array', function(v, path)
      if type(v) ~= 'table' then return false, issue(path, 'expected array, got ' .. describeValue(v)) end
      local n = #v
      local count = 0
      for k in pairs(v) do
        count = count + 1
        if math_type(k) ~= 'integer' or k < 1 or k > n then
          return false, issue(path, 'expected array, got table with key ' .. describeValue(k))
        end
      end
      local out = {}
      for i = 1, n do
        local ok, x = run(item, v[i], join(path, i))
        if not ok then return false, x end
        out[i] = x
      end
      return true, out
    end, { item = item })
  end

  ---Fixed-length sequence with a schema per position.
  function S.tuple(...)
    local items = { ... }
    return make('tuple', function(v, path)
      if type(v) ~= 'table' then return false, issue(path, 'expected tuple, got ' .. describeValue(v)) end
      local out = {}
      for i, item in ipairs(items) do
        local ok, x = run(item, v[i], join(path, i))
        if not ok then return false, x end
        out[i] = x
      end
      for k in pairs(v) do
        if math_type(k) ~= 'integer' or k < 1 or k > #items then
          return false, issue(path, 'unexpected tuple element ' .. describeValue(k))
        end
      end
      return true, out
    end, { items = items })
  end

  ---A table with known fields. Unknown keys are dropped by default;
  ---opts.extra = "error" rejects them, "keep" passes them through.
  ---@param fields table<string, Fx.Schema>
  ---@param opts? { extra?: "strip"|"error"|"keep" }
  function S.struct(fields, opts)
    local extra = opts and opts.extra or 'strip'
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return make('struct', function(v, path)
      if type(v) ~= 'table' then return false, issue(path, 'expected object, got ' .. describeValue(v)) end
      local out = {}
      for _, k in ipairs(keys) do
        local ok, x = run(fields[k], v[k], join(path, k))
        if not ok then return false, x end
        out[k] = x
      end
      if extra ~= 'strip' then
        for k, x in pairs(v) do
          if fields[k] == nil then
            if extra == 'error' then return false, issue(join(path, k), 'unexpected field') end
            out[k] = x
          end
        end
      end
      return true, out
    end, { fields = fields })
  end
  S.object = S.struct

  ---A table whose keys and values each match a schema.
  function S.record(keySchema, valueSchema)
    return make('record', function(v, path)
      if type(v) ~= 'table' then return false, issue(path, 'expected table, got ' .. describeValue(v)) end
      local out = {}
      for k, x in pairs(v) do
        local okK, kk = run(keySchema, k, join(path, tostring(k)))
        if not okK then return false, kk end
        local okV, vv = run(valueSchema, x, join(path, tostring(k)))
        if not okV then return false, vv end
        out[kk] = vv
      end
      return true, out
    end)
  end

  ---The first member that matches wins.
  function S.union(...)
    local members = { ... }
    return make('union', function(v, path)
      local msgs = {}
      for _, m in ipairs(members) do
        local ok, x = run(m, v, path)
        if ok then return true, x end
        msgs[#msgs + 1] = x
      end
      return false, issue(path, 'no union member matched (' .. table.concat(msgs, '; ') .. ')')
    end, { members = members })
  end

  ---A table discriminated by a field: S.tagged('type', { cash = S.struct{...}, bank = S.struct{...} })
  function S.tagged(field, variants)
    return make('tagged', function(v, path)
      if type(v) ~= 'table' then return false, issue(path, 'expected object, got ' .. describeValue(v)) end
      local variant = variants[v[field]]
      if not variant then
        return false, issue(join(path, field), 'unknown variant ' .. describeValue(v[field]))
      end
      local ok, out = run(variant, v, path)
      if not ok then return false, out end
      out[field] = v[field]
      return true, out
    end)
  end

  ---For recursive schemas: S.lazy(function() return Node end)
  function S.lazy(fn)
    local resolved
    return make('lazy', function(v, path)
      resolved = resolved or fn()
      return run(resolved, v, path)
    end)
  end

  -- FiveM types ---------------------------------------------------------------

  local function vector(n)
    local names = { 'x', 'y', 'z', 'w' }
    local ctor = ({ _G.vector2, _G.vector3, _G.vector4 })[n - 1]
    local kind = 'vector' .. n
    return make(kind, function(v, path)
      local comps = {}
      local tv = type(v)
      if tv == kind then
        for i = 1, n do comps[i] = v[names[i]] end
      elseif tv == 'table' then
        for i = 1, n do
          local c = v[names[i]]
          if c == nil then c = v[i] end
          comps[i] = c
        end
      else
        return false, issue(path, 'expected ' .. kind .. ', got ' .. describeValue(v))
      end
      for i = 1, n do
        local c = comps[i]
        if type(c) ~= 'number' or c ~= c or c == math.huge or c == -math.huge then
          return false, issue(join(path, names[i]), 'expected number, got ' .. describeValue(c))
        end
      end
      if ctor then return true, ctor(table.unpack(comps, 1, n)) end
      local out = {}
      for i = 1, n do out[names[i]] = comps[i] end
      return true, out
    end)
  end

  ---Accepts a CfxLua vector or a { x, y, z } / { x = , y = , z = } table; outputs a vector.
  S.vector2 = vector(2)
  S.vector3 = vector(3)
  S.vector4 = vector(4)

  ---A model or other hash: an integer, or a string that is hashed with joaat.
  S.hash = make('hash', function(v, path)
    if math_type(v) == 'integer' then return true, v end
    if type(v) == 'string' and v ~= '' then
      if _G.joaat then return true, _G.joaat(v) end
      if _G.GetHashKey then return true, _G.GetHashKey(v) end
      return true, v
    end
    return false, issue(path, 'expected hash or name, got ' .. describeValue(v))
  end)

  ---A network id (positive integer).
  S.netId = S.int:positive()

  ---Server only: the id of a connected player.
  S.player = S.int:refine(function(v)
    if _G.GetPlayerName then return _G.GetPlayerName(tostring(v)) ~= nil end
    return v > 0
  end, 'not a connected player')
end
