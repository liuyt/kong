do
  local meta = require "kong.meta"

  _G._KONG = {
    _NAME = meta._NAME,
    _VERSION = meta._VERSION
  }
end

do
  local randomseed = math.randomseed
  local seed

  --- Seeds the random generator, use with care.
  -- The uuid.seed() method will create a unique seed per worker
  -- process, using a combination of both time and the worker's pid.
  -- We only allow it to be called once to prevent third-party modules
  -- from overriding our correct seed (many modules make a wrong usage
  -- of `math.randomseed()` by calling it multiple times or do not use
  -- unique seed for Nginx workers).
  -- luacheck: globals math
  _G.math.randomseed = function()
    if not seed then
      -- If we're in runtime nginx, we have multiple workers so we _only_
      -- accept seeding when in the 'init_worker' phase.
      -- That is because that phase is the earliest one before the
      -- workers have a chance to process business logic, and because
      -- if we'd do that in the 'init' phase, the Lua VM is not forked
      -- yet and all workers would end-up using the same seed.
      if not ngx.RESTY_CLI and ngx.get_phase() ~= "init_worker" then
        error("math.randomseed() must be called in init_worker", 2)
      end

      seed = ngx.time() + ngx.worker.pid()
      ngx.log(ngx.DEBUG, "random seed: ", seed, " for worker nb ", ngx.worker.id(),
                         " (pid: ", ngx.worker.pid(), ")")
      randomseed(seed)
    else
      ngx.log(ngx.DEBUG, "attempt to seed random number generator, but ",
                         "already seeded with ", seed)
    end

    return seed
  end
end

if ngx.RESTY_CLI then
  do
    -- ngx.shared.DICT proxy
    -- https://github.com/bsm/fakengx/blob/master/fakengx.lua
    local SharedDict = {}
    local function set(data, key, value)
      data[key] = {
        value = value,
        info = {expired = false}
      }
    end
    function SharedDict:new()
      return setmetatable({data = {}}, {__index = self})
    end
    function SharedDict:get(key)
      return self.data[key] and self.data[key].value, nil
    end
    function SharedDict:set(key, value)
      set(self.data, key, value)
      return true, nil, false
    end
    SharedDict.safe_set = SharedDict.set
    function SharedDict:add(key, value)
      if self.data[key] ~= nil then
        return false, "exists", false
      end
      set(self.data, key, value)
      return true, nil, false
    end
    function SharedDict:replace(key, value)
      if self.data[key] == nil then
        return false, "not found", false
      end
      set(self.data, key, value)
      return true, nil, false
    end
    function SharedDict:delete(key)
      self.data[key] = nil
      return true
    end
    function SharedDict:incr(key, value)
      if not self.data[key] then
        return nil, "not found"
      elseif type(self.data[key].value) ~= "number" then
        return nil, "not a number"
      end
      self.data[key].value = self.data[key].value + value
      return self.data[key].value, nil
    end
    function SharedDict:flush_all()
      for _, item in pairs(self.data) do
        item.info.expired = true
      end
    end
    function SharedDict:flush_expired(n)
      local data = self.data
      local flushed = 0

      for key, item in pairs(self.data) do
        if item.info.expired then
          data[key] = nil
          flushed = flushed + 1
          if n and flushed == n then
            break
          end
        end
      end
      self.data = data
      return flushed
    end
    function SharedDict:get_keys(n)
      n = n or 1024
      local i = 0
      local keys = {}
      for k in pairs(self.data) do
        keys[#keys+1] = k
        i = i + 1
        if n ~= 0 and i == n then
          break
        end
      end
      return keys
    end

    -- hack
    _G.ngx.shared = setmetatable({}, {
      __index = function(self, key)
        local shm = rawget(self, key)
        if not shm then
          shm = SharedDict:new()
          rawset(self, key, SharedDict:new())
        end
        return shm
      end
    })
  end
end
