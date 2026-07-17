-- Author: sunfang1cn@gmail.com

local service = rawget(_G, "AIRPLAY_SERVICE")
if not service then
  print("airplay_service: not running")
  return
end

local state = service.get_state()
print("airplay_service:", state.phase, state.error or "ok")
local result = service.self_test()
for _, check in ipairs(result.checks) do
  print(check.ok and "PASS" or "FAIL", check.name)
end
