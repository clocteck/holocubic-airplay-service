-- Author: sunfang1cn@gmail.com
-- Restart the managed service with a short gap so the old TCP/UDP resources
-- are released before the replacement instance binds its ports.

pcall(function() app.stop_service("airplay_service") end)

local start_timer = tmr.create()
start_timer:alarm(2500, tmr.ALARM_SINGLE, function()
  pcall(function() app.start_service("airplay_service") end)
end)

local exit_timer = tmr.create()
exit_timer:alarm(5000, tmr.ALARM_SINGLE, function()
  if app and app.exit then pcall(app.exit) end
end)
