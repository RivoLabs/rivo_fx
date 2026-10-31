-- Typed resource KVP (client and server). Values are stored as JSON and
-- checked with a schema on the way in and on the way out.
--   local Prefs = Fx.kvp.typed('prefs:', S.struct { volume = S.number:between(0, 1) })
--   Fx.yield(Prefs:set('ui', { volume = 0.4 }))
--   local prefs = Fx.yield(Prefs:get('ui'))   -- nil when unset
return function(Fx)
  local kvp = {}

  kvp.KvpInvalid = Fx.TaggedError('KvpInvalid')         -- value failed its schema on write
  kvp.KvpDecodeError = Fx.TaggedError('KvpDecodeError') -- stored value is not valid JSON or fails its schema

  local function same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end

  local function decode(key, raw, schema)
    local ok, value = pcall(json.decode, raw)
    if not ok then
      return Fx.fail(kvp.KvpDecodeError { key = key, message = 'stored value is not valid JSON' })
    end
    if schema then
      local valid, out = schema:validate(value)
      if not valid then return Fx.fail(kvp.KvpDecodeError { key = key, message = out }) end
      value = out
    end
    return Fx.succeed(value)
  end

  ---Read key. Succeeds with nil when it is not set.
  ---@param key string
  ---@param schema? Fx.Schema
  function kvp.get(key, schema)
    return Fx.suspend(function()
      local raw = GetResourceKvpString(key)
      if raw == nil then return Fx.succeed(nil) end
      return decode(key, raw, schema)
    end)
  end

  ---Write key. With a schema the value is checked (and transformed) first.
  ---@param key string
  ---@param value any
  ---@param schema? Fx.Schema
  function kvp.set(key, value, schema)
    return Fx.suspend(function()
      if schema then
        local valid, out = schema:validate(value)
        if not valid then return Fx.fail(kvp.KvpInvalid { key = key, message = out }) end
        value = out
      end
      local ok, encoded = pcall(json.encode, value)
      if not ok or encoded == nil then
        return Fx.fail(kvp.KvpInvalid { key = key, message = 'value cannot be encoded as JSON' })
      end
      -- JSON cannot hold every Lua table (mixed array and string keys, holes,
      -- non-string keys): refuse anything that would come back different.
      local okBack, back = pcall(json.decode, encoded)
      if not okBack or not same(value, back) then
        return Fx.fail(kvp.KvpInvalid { key = key, message = 'value does not survive JSON encoding (mixed array and string keys, holes, or non-string keys?)' })
      end
      SetResourceKvp(key, encoded)
      return Fx.unit
    end)
  end

  ---@param key string
  function kvp.delete(key)
    return Fx.sync(function() DeleteResourceKvp(key) end)
  end

  ---Every key starting with prefix.
  ---@param prefix string
  function kvp.keys(prefix)
    return Fx.sync(function()
      local out = {}
      local handle = StartFindKvp(prefix)
      if handle == -1 then return out end
      while true do
        local key = FindKvp(handle)
        if not key then break end
        out[#out + 1] = key
      end
      EndFindKvp(handle)
      table.sort(out)
      return out
    end)
  end

  local Typed = {}
  Typed.__index = Typed

  function Typed:get(id) return kvp.get(self.prefix .. id, self.schema) end
  function Typed:set(id, value) return kvp.set(self.prefix .. id, value, self.schema) end
  function Typed:delete(id) return kvp.delete(self.prefix .. id) end

  ---Every stored id under the prefix (without it).
  function Typed:ids()
    local n = #self.prefix
    return kvp.keys(self.prefix):map(function(keys)
      for i, k in ipairs(keys) do keys[i] = k:sub(n + 1) end
      return keys
    end)
  end

  ---All entries as { [id] = value }. Fails on the first entry that does not decode.
  function Typed:all()
    local store = self
    return self:ids():flatMap(function(ids)
      return Fx.forEach(ids, function(id) return store:get(id) end):map(function(values)
        local out = {}
        for i, id in ipairs(ids) do out[id] = values[i] end
        return out
      end)
    end)
  end

  ---A family of keys sharing a prefix and a schema.
  ---@param prefix string
  ---@param schema Fx.Schema
  function kvp.typed(prefix, schema)
    return setmetatable({ prefix = prefix, schema = schema }, Typed)
  end

  return kvp
end
