-- oxmysql as typed effects (server).
--   local Row = S.struct { id = S.int, name = S.string, money = S.int }
--   local rows = Fx.yield(Fx.db.query('SELECT id, name, money FROM players WHERE money > ?', { 100 }, { row = Row }))
--   local id = Fx.yield(Fx.db.insert('INSERT INTO logs (msg) VALUES (?)', { 'hi' }))
-- Every failure is a typed SqlError (or SqlDecodeError when a row fails its
-- schema), so it can be caught, retried or mapped like any other error.
-- Queries go to oxmysql unless a Database service is provided (Fx.db.Database
-- tag), which is how tests swap in a fake.
return function(Fx)
  local db = {}

  db.SqlError = Fx.TaggedError('SqlError')
  db.SqlDecodeError = Fx.TaggedError('SqlDecodeError')

  ---Service tag. A provided implementation has the same methods as
  ---Fx.db.oxmysql: query, single, scalar, insert, update, prepare, transaction,
  ---each fun(sql, params, done) calling done(result, err).
  db.Database = Fx.Tag('rivo_fx/Database')

  -- The live driver: oxmysql exports in promise style, so failures come back
  -- as (nil, message) instead of only being printed.
  local function oxCall(method)
    return function(sql, params, done)
      local ox = exports.oxmysql
      local ok, err = pcall(function()
        ox[method](ox, sql, params or {}, function(result, e) done(result, e) end, Fx.resourceName, true)
      end)
      if not ok then done(nil, err) end
    end
  end

  db.oxmysql = {}
  for _, m in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'prepare' }) do
    db.oxmysql[m] = oxCall(m)
  end
  function db.oxmysql.transaction(queries, params, done)
    local ox = exports.oxmysql
    local ok, err = pcall(function()
      ox:transaction(queries, params or {}, function(result, e) done(result, e) end, Fx.resourceName, true)
    end)
    if not ok then done(nil, err) end
  end

  ---Layer providing the live oxmysql driver explicitly.
  db.layer = Fx.Layer.succeed(db.Database, db.oxmysql)

  local function message(err)
    if type(err) == 'table' then return tostring(err.message or err.error or err) end
    local s = tostring(err)
    -- An error thrown through the export call arrives wrapped in FiveM's
    -- "An error occurred while calling export" text; keep the database's line.
    local inner = s:match('\n%s*Error: ([^\n]+)') or s:match('^Error: ([^\n]+)')
    if inner then return inner end
    -- oxmysql: "<res> was unable to execute a query!\nQuery: ...\n<params>\n<db error>"
    if s:find('was unable to execute a query!', 1, true) then
      local last = s:match('([^\n]+)%s*$')
      if last then return last end
    end
    return (s:gsub('%^%d', ''))
  end

  local function run(method, sql, params)
    return Fx.serviceOption(db.Database):flatMap(function(impl)
      local driver = impl or db.oxmysql
      return Fx.async(function(resume)
        driver[method](sql, params, function(result, err)
          if err ~= nil and err ~= false then
            resume(Fx.fail(db.SqlError { method = method, sql = sql, message = message(err) }))
          else
            resume(Fx.succeed(result))
          end
        end)
      end)
    end)
  end

  local function decodeRow(schema, row, index, sql)
    local ok, v = schema:validate(row)
    if ok then return true, v end
    return false, db.SqlDecodeError { sql = sql, index = index, message = v }
  end

  ---Rows as an array. opts.row checks (and transforms) every row.
  ---@param sql string
  ---@param params? table
  ---@param opts? { row?: Fx.Schema }
  function db.query(sql, params, opts)
    local eff = run('query', sql, params):map(function(rows) return rows or {} end)
    local schema = opts and opts.row
    if not schema then return eff end
    return eff:flatMap(function(rows)
      local out = {}
      for i, row in ipairs(rows) do
        local ok, v = decodeRow(schema, row, i, sql)
        if not ok then return Fx.fail(v) end
        out[i] = v
      end
      return Fx.succeed(out)
    end)
  end

  ---The first row, or nil. opts.row checks it.
  function db.single(sql, params, opts)
    local eff = run('single', sql, params)
    local schema = opts and opts.row
    if not schema then return eff end
    return eff:flatMap(function(row)
      if row == nil then return Fx.succeed(nil) end
      local ok, v = decodeRow(schema, row, 1, sql)
      if ok then return Fx.succeed(v) end
      return Fx.fail(v)
    end)
  end

  ---The first column of the first row, or nil. opts.value checks it.
  function db.scalar(sql, params, opts)
    local eff = run('scalar', sql, params)
    local schema = opts and opts.value
    if not schema then return eff end
    return eff:flatMap(function(value)
      if value == nil then return Fx.succeed(nil) end
      local ok, v = schema:validate(value)
      if ok then return Fx.succeed(v) end
      return Fx.fail(db.SqlDecodeError { sql = sql, index = 1, message = v })
    end)
  end

  ---The new row's id.
  function db.insert(sql, params) return run('insert', sql, params) end

  ---The number of affected rows.
  function db.update(sql, params) return run('update', sql, params) end

  ---Run one statement for many parameter sets (oxmysql prepare).
  function db.prepare(sql, params) return run('prepare', sql, params) end

  ---Run statements in one transaction. queries is oxmysql's format: a list of
  ---{ query = sql, values = params } (or sql strings with shared params).
  ---Succeeds with true when committed; fails with SqlError when rolled back.
  function db.transaction(queries, params)
    return Fx.serviceOption(db.Database):flatMap(function(impl)
      local driver = impl or db.oxmysql
      return Fx.async(function(resume)
        driver.transaction(queries, params, function(result, err)
          if err ~= nil and err ~= false then
            resume(Fx.fail(db.SqlError { method = 'transaction', message = message(err) }))
          elseif result == false or result == nil then
            resume(Fx.fail(db.SqlError { method = 'transaction', message = 'transaction rolled back' }))
          else
            resume(Fx.succeed(true))
          end
        end)
      end)
    end)
  end

  return db
end
