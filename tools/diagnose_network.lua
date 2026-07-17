-- Author: sunfang1cn@gmail.com
-- Hold a directly loaded AirPlay service open briefly so a workstation can
-- probe its RTSP listener. The managed service is restored before exit.

local OUTPUT = "/sd/airplay_service_network_diag.json"
local ENTRY = "/sd/apps/airplay_service/main.lua"
local result = {}
local loaded_service = nil

local function copy(value, depth)
  depth = depth or 0
  if depth > 5 then return "<depth-limit>" end
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then
    return value
  end
  if kind ~= "table" then return tostring(value) end
  local out = {}
  for key, child in pairs(value) do out[tostring(key)] = copy(child, depth + 1) end
  return out
end

local function write_result()
  local codec = rawget(_G, "json") or rawget(_G, "sjson")
  local ok, encoded = pcall(function() return codec.encode(result) end)
  if not ok then
    encoded = '{"diagnostic_error":"' .. tostring(encoded):gsub('["\\]', '\\%0') .. '"}'
  end
  file.putcontents(OUTPUT, encoded)
end

local function finish()
  if type(loaded_service) == "table" and type(loaded_service.get_state) == "function" then
    local ok, value = pcall(loaded_service.get_state)
    result.state_ok = ok
    if ok then result.state = copy(value) else result.state_error = tostring(value) end
    result.core_error = copy(loaded_service.core_error)
  end
  if type(loaded_service) == "table" and type(loaded_service.stop) == "function" then
    pcall(function() loaded_service.stop("diagnostic complete") end)
  end
  write_result()
  pcall(function() app.start_service("airplay_service") end)
  if app and app.exit then pcall(app.exit) end
end

local function load_service()
  local compile_ok, chunk_or_error, loadfile_error = pcall(loadfile, ENTRY)
  result.compile_ok = compile_ok and type(chunk_or_error) == "function"
  if not result.compile_ok then
    result.compile_error = tostring(loadfile_error or chunk_or_error)
    write_result()
    pcall(function() app.start_service("airplay_service") end)
    if app and app.exit then pcall(app.exit) end
    return
  end
  local load_ok, value = pcall(chunk_or_error)
  result.load_ok = load_ok
  if load_ok then
    loaded_service = type(value) == "table" and value or rawget(_G, "AIRPLAY_SERVICE")
  else
    result.load_error = tostring(value)
  end
  if not load_ok then
    write_result()
    pcall(function() app.start_service("airplay_service") end)
    if app and app.exit then pcall(app.exit) end
    return
  end
  local timer = tmr.create()
  timer:alarm(6000, tmr.ALARM_SINGLE, finish)
end

local stop_ok, stop_result, stop_error = pcall(function()
  return app.stop_service("airplay_service")
end)
result.stop_call_ok = stop_ok
result.stop_result = copy(stop_result)
result.stop_error = copy(stop_error)

local timer = tmr.create()
timer:alarm(500, tmr.ALARM_SINGLE, load_service)
