-- Tagged errors and small data helpers.
return function(Fx)
  local type, pairs, tostring, setmetatable = type, pairs, tostring, setmetatable

  ---Readable one-line rendering of plain Lua values, for logs and errors.
  function Fx.inspect(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == 'string' then return string.format('%q', v) end
    if t ~= 'table' then return tostring(v) end
    if depth > 3 then return '{...}' end
    local parts, keys = {}, {}
    for k in pairs(v) do
      if k ~= '_tag' and k ~= '_fxTagged' then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local key = type(k) == 'string' and k:match('^[%a_][%w_]*$') and k or ('[' .. Fx.inspect(k, depth + 1) .. ']')
      parts[#parts + 1] = key .. ' = ' .. Fx.inspect(v[k], depth + 1)
    end
    local body = #parts > 0 and ('{ ' .. table.concat(parts, ', ') .. ' }') or '{}'
    if v._tag then return tostring(v._tag) .. ' ' .. body end
    return body
  end

  local ErrorProto = {}

  ---Fail with this error: `return NotFound { id = 1 }:fail()`
  function ErrorProto:fail() return Fx.fail(self) end


  ---Declare an error type with a _tag. Instances are plain tables with fields
  ---from props, so they serialise cleanly over the network.
  ---  local PlayerNotFound = Fx.TaggedError('PlayerNotFound')
  ---  return PlayerNotFound { src = src }:fail()
  ---@param tag string
  ---@param fields? table<string, table> optional schema per field, checked on construction
  ---@return Fx.TaggedErrorClass
  -- Tags this resource declared. Metrics label failures by tag only when it
  -- is one of these, so an error a client made up cannot add label values.
  Fx._declaredTags = Fx._declaredTags or {}

  function Fx.TaggedError(tag, fields)
    Fx._declaredTags[tag] = true
    local mt = {
      __index = ErrorProto,
      __name = tag,
      __tostring = function(self)
        if type(self.message) == 'string' and self.message ~= '' then
          return tag .. ': ' .. self.message
        end
        return Fx.inspect(self)
      end,
    }
    local cls = { _tag = tag }
    function cls.is(v) return type(v) == 'table' and v._tag == tag end
    setmetatable(cls, {
      __call = function(_, props)
        local e = {}
        if props then for k, v in pairs(props) do e[k] = v end end
        if fields and Fx.S then
          local ok, issue = Fx.S.struct(fields):validate(e)
          if not ok then error(('invalid fields for %s: %s'):format(tag, issue), 2) end
        end
        e._tag = tag
        e._fxTagged = true
        return setmetatable(e, mt)
      end,
      __tostring = function() return 'TaggedError(' .. tag .. ')' end,
    })
    return cls
  end

  ---Rebuild a tagged error from a plain table (for example one received over the network).
  function Fx.taggedFromTable(t)
    local e = {}
    for k, v in pairs(t) do e[k] = v end
    e._fxTagged = true
    return setmetatable(e, {
      __index = ErrorProto,
      __name = tostring(t._tag),
      __tostring = function(self) return Fx.inspect(self) end,
    })
  end

  ---Copy of a tagged error with only serialisable fields (for the wire).
  function Fx.serializeError(e)
    local out = {}
    local function plain(v, depth)
      local t = type(v)
      if t == 'function' or t == 'thread' or t == 'userdata' then return nil end
      if t ~= 'table' then return v end
      if depth > 8 then return nil end
      local o = {}
      for k, x in pairs(v) do
        if k ~= '_fxTagged' then o[k] = plain(x, depth + 1) end
      end
      return o
    end
    for k, v in pairs(e) do
      if k ~= '_fxTagged' then out[k] = plain(v, 1) end
    end
    return out
  end

  -- Built-in errors
  Fx.TimeoutError = Fx.TaggedError('TimeoutError')
  Fx.NoSuchElementError = Fx.TaggedError('NoSuchElementError')
  Fx.UnknownError = Fx.TaggedError('UnknownError')
end
