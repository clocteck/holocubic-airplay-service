-- Author: sunfang1cn@gmail.com
-- One-shot on-device diagnostic for HoloCubic's service manager.
-- Intended to be launched temporarily through DevTools as the DevRun app.

local OUTPUT = "/sd/airplay_service_diag.json"

local function scalar(value)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then
    return value
  end
  if value == nil then return nil end
  return tostring(value)
end

local function service_snapshot()
  local out = {}
  local ok, services = pcall(function() return app.services() end)
  if not ok then return out, tostring(services) end
  if type(services) ~= "table" then return out, "app.services returned " .. type(services) end
  for index, item in ipairs(services) do
    local copy = {}
    if type(item) == "table" then
      for key, value in pairs(item) do
        copy[tostring(key)] = scalar(value)
      end
    else
      copy.value = scalar(item)
    end
    out[index] = copy
  end
  return out
end

local result = {
  before = nil,
  before_error = nil,
  start_call_ok = false,
  start_result = nil,
  start_error = nil,
  immediate_last_error = nil,
  after = nil,
  after_error = nil,
  final_last_error = nil,
}

result.before, result.before_error = service_snapshot()
local call_ok, start_result, start_error = pcall(function()
  return app.start_service("airplay_service")
end)
result.start_call_ok = call_ok
result.start_result = scalar(start_result)
result.start_error = scalar(start_error)
result.immediate_last_error = scalar(app.last_error and app.last_error() or nil)

local function finish()
  result.after, result.after_error = service_snapshot()
  result.final_last_error = scalar(app.last_error and app.last_error() or nil)
  local codec = rawget(_G, "json") or rawget(_G, "sjson")
  local ok, encoded = pcall(function() return codec.encode(result) end)
  if not ok then
    encoded = '{"diagnostic_error":"' .. tostring(encoded):gsub('["\\]', '\\%0') .. '"}'
  end
  file.putcontents(OUTPUT, encoded)
  if app and app.exit then pcall(app.exit) end
end

local timer = tmr.create()
timer:alarm(1500, tmr.ALARM_SINGLE, finish)
