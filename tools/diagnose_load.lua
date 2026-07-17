-- Author: sunfang1cn@gmail.com
-- Load the installed service inside DevRun so top-level Lua errors are
-- observable even when the firmware service manager discards them.

local OUTPUT = "/sd/airplay_service_load_diag.json"
local ENTRY = "/sd/apps/airplay_service/main.lua"

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

local result = {}
local compile_ok, chunk_or_error, loadfile_error = pcall(loadfile, ENTRY)
result.compile_call_ok = compile_ok
result.compile_ok = compile_ok and type(chunk_or_error) == "function"
if not result.compile_ok then
  result.compile_error = tostring(loadfile_error or chunk_or_error)
end

local service = nil
if result.compile_ok then
  local load_ok, loaded_or_error = pcall(chunk_or_error)
  result.load_ok = load_ok
  if load_ok then
    service = type(loaded_or_error) == "table" and loaded_or_error or rawget(_G, "AIRPLAY_SERVICE")
    result.return_type = type(service)
    if type(service) == "table" then
      result.core_error = copy(service.core_error)
    end
    if type(service) == "table" and type(service.get_state) == "function" then
      local state_ok, state_or_error = pcall(service.get_state)
      result.state_ok = state_ok
      if state_ok then result.state = copy(state_or_error)
      else result.state_error = tostring(state_or_error) end
    end
  else
    result.load_error = tostring(loaded_or_error)
  end
end

local codec = rawget(_G, "json") or rawget(_G, "sjson")
local encode_ok, encoded = pcall(function() return codec.encode(result) end)
if not encode_ok then
  encoded = '{"diagnostic_error":"' .. tostring(encoded):gsub('["\\]', '\\%0') .. '"}'
end
file.putcontents(OUTPUT, encoded)

if type(service) == "table" and type(service.stop) == "function" then
  pcall(function() service.stop("diagnostic complete") end)
end
if app and app.exit then pcall(app.exit) end
