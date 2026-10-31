-- Typed configuration from convars and config files.
--   local Config = Fx.config.struct {
--     maxCars = Fx.config.int('garage:maxCars', 5),
--     webhook = Fx.config.string('garage:webhook'),
--   }
--   local cfg = Fx.yield(Config)
return function(Fx)
  local config = {}
  local MISSING = '\0rivo_fx:missing\0'

  config.ConfigError = Fx.TaggedError('ConfigError')

  local function read(name, default, parse, kind)
    return Fx.suspend(function()
      local raw = GetConvar(name, MISSING)
      if raw == MISSING or raw == '' then
        if default ~= nil then return Fx.succeed(default) end
        return Fx.fail(config.ConfigError { name = name, message = ('convar %s is not set'):format(name) })
      end
      local ok, v = parse(raw)
      if ok then return Fx.succeed(v) end
      return Fx.fail(config.ConfigError {
        name = name, message = ('convar %s: expected %s, got %q'):format(name, kind, raw),
      })
    end)
  end

  function config.string(name, default)
    return read(name, default, function(raw) return true, raw end, 'string')
  end

  function config.number(name, default)
    return read(name, default, function(raw)
      local n = tonumber(raw)
      return n ~= nil and n == n, n
    end, 'number')
  end

  function config.int(name, default)
    return read(name, default, function(raw)
      local n = math.tointeger(tonumber(raw))
      return n ~= nil, n
    end, 'integer')
  end

  local BOOLS = { ['true'] = true, ['1'] = true, yes = true, on = true,
    ['false'] = false, ['0'] = false, no = false, off = false }
  function config.bool(name, default)
    return read(name, default, function(raw)
      local b = BOOLS[raw:lower()]
      return b ~= nil, b
    end, 'boolean')
  end

  function config.enum(name, values, default)
    local allowed = {}
    for _, v in ipairs(values) do allowed[v] = true end
    return read(name, default, function(raw) return allowed[raw] == true, raw end,
      'one of ' .. table.concat(values, ', '))
  end

  ---A convar holding JSON, checked with a schema.
  function config.json(name, schema, default)
    return read(name, default, function(raw)
      local ok, decoded = pcall(json.decode, raw)
      if not ok or decoded == nil then return false end
      local valid, v = schema:validate(decoded)
      return valid, v
    end, 'JSON matching the schema')
  end

  ---Read several config values into one table (they are all reported if missing).
  function config.struct(fields)
    return Fx.all(fields)
  end

  ---Load a config file from a resource (.json, or .lua returning a table) and
  ---check it with a schema. opts.resource defaults to the current resource.
  function config.file(path, schema, opts)
    local res = opts and opts.resource or Fx.resourceName
    return Fx.suspend(function()
      local src = LoadResourceFile(res, path)
      if not src then
        return Fx.fail(config.ConfigError { name = path, message = ('%s/%s not found'):format(res, path) })
      end
      local data
      if path:match('%.json$') then
        local ok, v = pcall(json.decode, src)
        if not ok or v == nil then
          return Fx.fail(config.ConfigError { name = path, message = 'invalid JSON' })
        end
        data = v
      else
        local chunk, err = load(src, '@@' .. res .. '/' .. path, 't', {})
        if not chunk then return Fx.fail(config.ConfigError { name = path, message = err }) end
        local ok, v = pcall(chunk)
        if not ok then return Fx.fail(config.ConfigError { name = path, message = tostring(v) }) end
        data = v
      end
      local valid, v = schema:validate(data)
      if not valid then return Fx.fail(config.ConfigError { name = path, message = v }) end
      return Fx.succeed(v)
    end)
  end

  return config
end
