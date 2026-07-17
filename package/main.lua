-- HoloCubic AirPlay 1 / RAOP background service.
-- Author: sunfang1cn@gmail.com
--
-- The Lua layer owns discovery, RTSP and metadata.  On SDK3 firmware the
-- bundled core owns realtime RTP/control/timing UDP in a native worker; older
-- hosts retain the Lua UDP fallback.  The core also supplies RSA/AES/ALAC,
-- mono speaker output and PSRAM jitter buffering.

local previous = rawget(_G, "AIRPLAY_SERVICE")
if previous and previous.stop then
  pcall(function() previous.stop("reload") end)
end

local configured = rawget(_G, "AIRPLAY_SERVICE_CONFIG")

AIRPLAY_SERVICE = {
  VERSION = "0.3.24",
  APP_DIR = "/sd/apps/airplay_service",
  MODULE_PATH = "/sd/apps/airplay_service/modules/airplay_core.so",
  STATUS_PATH = "/sd/apps/airplay_service/status.json",
  WEBUI_CONFIG_PATH = "/sd/apps/airplay_service/webui_config.lua",
  WEBUI_PAGE_PATH = "/sd/apps/airplay_service/webui.html",
  WEBUI_ROUTE_BASE = "/airplay_service",
  running = true,
  timers = {},
  clients = {},
  subscribers = {},
  core = nil,
  core_error = nil,
  native_udp_available = false,
  native_udp = false,
  output_owned = false,
  network_ip = nil,
  system_ip = nil,
  ip_lookup_pending = false,
  ip_lookup_ms = 0,
  ip_lookup_error = nil,
  audio_focus_handler = nil,
  overlay = nil,
  overlay_dirty = false,
  overlay_last_run_ms = nil,
  webui_routes = {},
}

local APP = AIRPLAY_SERVICE

local defaults = {
  name = "HoloCubic",
  rtsp_port = 5000,
  rtsp_idle_timeout_s = 7200,
  audio_port = 6000,
  control_port = 6001,
  timing_port = 6002,
  native_udp_enabled = true,
  i2s_port = 0,
  data_out_pin = 48,
  sample_rate = 44100,
  channels = 2,
  output_channels = 1,
  bits = 16,
  dma_buffer_count = 12,
  dma_buffer_len = 512,
  prebuffer_packets = 160,
  max_jitter_packets = 96,
  missing_wait_ticks = 192,
  audio_task_priority = 10,
  audio_task_core = -1,
  output_task_core = 0,
  mdns_interval_ms = 30000,
  network_poll_ms = 2000,
  drain_interval_ms = 10,
  overlay_refresh_ms = 100,
  -- Separates display redraws from frequent RTSP metadata updates.  This is
  -- deliberately not exposed as a normal WebUI control: 1 s keeps foreground
  -- apps responsive while title state still updates immediately.
  overlay_min_render_interval_ms = 1000,
  overlay_enabled = true,
  overlay_position = "top",
  overlay_background = "transparent",
  overlay_font_size = 16,
  timing_poll_ms = 100,
  timing_initial_interval_ms = 300,
  timing_interval_ms = 3000,
  debug = false,
  lyrics_dir = nil,
  ip = nil,
}

local function merge(dst, src)
  if type(src) ~= "table" then return dst end
  for k, v in pairs(src) do dst[k] = v end
  return dst
end

APP.config = merge({}, defaults)
local ok_file, file_config = pcall(dofile, APP.APP_DIR .. "/config.lua")
if ok_file and type(file_config) == "table" then merge(APP.config, file_config) end
local ok_webui_file, webui_config = pcall(dofile, APP.WEBUI_CONFIG_PATH)
if ok_webui_file and type(webui_config) == "table" then merge(APP.config, webui_config) end
merge(APP.config, configured)

APP.state = {
  version = APP.VERSION,
  phase = "starting",
  ready = false,
  connected = false,
  playing = false,
  client_ip = nil,
  session_id = nil,
  codec = nil,
  sample_rate = APP.config.sample_rate,
  channels = APP.config.channels,
  volume_db = 0,
  position_ms = 0,
  duration_ms = 0,
  title = "",
  artist = "",
  album = "",
  artwork_mime = nil,
  artwork_bytes = 0,
  level_left = 0,
  level_right = 0,
  error = nil,
  warning = nil,
  native_core = false,
  native_udp = false,
  auth_available = false,
  alac_available = false,
  encryption_available = false,
  focus_conflict = false,
  last_rtsp_method = nil,
  last_rtsp_ms = nil,
  last_rtsp_response_method = nil,
  last_rtsp_response_code = nil,
  last_rtsp_response_queued_ms = nil,
  last_rtsp_response_sent_ms = nil,
  last_rtsp_send_error = nil,
  last_disconnect_pending_responses = 0,
  last_disconnect_pending_methods = "",
  last_rtsp_response_latency_ms = 0,
  max_rtsp_response_latency_ms = 0,
  last_overlay_update_ms = nil,
  last_overlay_render_ms = 0,
  max_overlay_render_ms = 0,
  overlay_error = nil,
  last_session_end = nil,
  last_session_end_ms = nil,
  last_timing_response_ms = nil,
  last_timing_roundtrip_ms = nil,
  last_sync_ms = nil,
  sync_rtp_timestamp = nil,
  sync_latency_frames = nil,
  metrics = {
    rtsp_requests = 0,
    rtsp_responses_queued = 0,
    rtsp_responses_sent = 0,
    rtsp_send_errors = 0,
    rtsp_response_over_250ms = 0,
    rtsp_response_over_1000ms = 0,
    overlay_updates = 0,
    overlay_updates_coalesced = 0,
    overlay_errors = 0,
    rtp_received = 0,
    rtp_written = 0,
    rtp_lost = 0,
    rtp_late = 0,
    rtp_dropped = 0,
    resend_requests = 0,
    bytes_received = 0,
    timing_requests = 0,
    timing_responses = 0,
    sync_packets = 0,
  },
}

local S = APP.state

local function log(...)
  if not APP.config.debug then return end
  print("[airplay]", ...)
end

local function shallow_copy(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do out[k] = v end
  end
  return out
end

local function snapshot()
  local out = shallow_copy(S)
  out.metrics = shallow_copy(S.metrics)
  return out
end

local function notify()
  if APP.overlay_dirty then
    S.metrics.overlay_updates_coalesced = S.metrics.overlay_updates_coalesced + 1
  end
  APP.overlay_dirty = true
  if #APP.subscribers == 0 then return end
  local value = snapshot()
  for i = #APP.subscribers, 1, -1 do
    local fn = APP.subscribers[i]
    local ok = pcall(fn, value)
    if not ok then table.remove(APP.subscribers, i) end
  end
end

local WEBUI_CONFIG_KEYS = {
  "overlay_enabled",
  "overlay_position",
  "overlay_background",
  "overlay_font_size",
}

local function webui_config_document()
  return {
    overlay_enabled = APP.config.overlay_enabled ~= false,
    overlay_position = APP.config.overlay_position == "bottom" and "bottom" or "top",
    overlay_background = APP.config.overlay_background == "gray" and "gray" or "transparent",
    overlay_font_size = tonumber(APP.config.overlay_font_size) or 16,
  }
end

local function url_decode(value)
  value = tostring(value or ""):gsub("+", " ")
  return value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

local function parse_query(query)
  local values = {}
  for pair in tostring(query or ""):gmatch("[^&]+") do
    local key, value = pair:match("^([^=]*)=(.*)$")
    if not key then key, value = pair, "" end
    values[url_decode(key)] = url_decode(value)
  end
  return values
end

local function json_response(status, value)
  local codec = rawget(_G, "json") or rawget(_G, "sjson")
  local ok, body = pcall(function() return codec.encode(value) end)
  if not ok or type(body) ~= "string" then
    status, body = "500 Internal Server Error", "{\"ok\":false,\"error\":\"json encode failed\"}"
  end
  return {
    status = status or "200 OK",
    type = "application/json; charset=utf-8",
    headers = { ["cache-control"] = "no-store", ["connection"] = "close" },
    body = body,
  }
end

local function text_response(status, content_type, body, headers)
  headers = headers or {}
  headers["cache-control"] = headers["cache-control"] or "no-store"
  headers["connection"] = headers["connection"] or "close"
  return { status = status or "200 OK", type = content_type, headers = headers, body = body or "" }
end

local function persist_webui_config()
  if not file or not file.putcontents then return nil, "file.putcontents unavailable" end
  local config = webui_config_document()
  local rows = {
    "-- Persistent WebUI preferences for AirPlay Service.",
    "-- This file is maintained by /airplay_service/ and intentionally does not replace config.lua.",
    "return {",
  }
  for _, key in ipairs(WEBUI_CONFIG_KEYS) do
    local value = config[key]
    if type(value) == "string" then
      rows[#rows + 1] = "  " .. key .. " = " .. string.format("%q", value) .. ","
    else
      rows[#rows + 1] = "  " .. key .. " = " .. tostring(value) .. ","
    end
  end
  rows[#rows + 1] = "}"
  local ok, result = pcall(file.putcontents, APP.WEBUI_CONFIG_PATH, table.concat(rows, "\n") .. "\n")
  if not ok or not result then return nil, tostring(result or "write failed") end
  return true
end

function APP.apply_webui_config(values, save)
  values = values or {}
  local changed = false
  local enabled = values.overlay_enabled
  if enabled ~= nil then
    local next_enabled = tostring(enabled) == "1" or tostring(enabled):lower() == "true" or tostring(enabled):lower() == "on"
    if APP.config.overlay_enabled ~= next_enabled then APP.config.overlay_enabled, changed = next_enabled, true end
  end
  if values.overlay_position ~= nil then
    local position = tostring(values.overlay_position) == "bottom" and "bottom" or "top"
    if APP.config.overlay_position ~= position then APP.config.overlay_position, changed = position, true end
  end
  if values.overlay_background ~= nil then
    local background = tostring(values.overlay_background) == "gray" and "gray" or "transparent"
    if APP.config.overlay_background ~= background then APP.config.overlay_background, changed = background, true end
  end
  if values.overlay_font_size ~= nil then
    local size = tonumber(values.overlay_font_size) or APP.config.overlay_font_size
    size = size >= 18 and 18 or (size <= 14 and 14 or 16)
    if APP.config.overlay_font_size ~= size then APP.config.overlay_font_size, changed = size, true end
  end
  if changed and APP.overlay and APP.overlay.configure then
    local ok, err = pcall(APP.overlay.configure, APP.overlay, APP.config)
    if not ok then S.overlay_error = tostring(err) end
  end
  if changed then
    APP.overlay_last_run_ms = nil
    APP.overlay_dirty = true
    notify()
  end
  if save then
    local ok, err = persist_webui_config()
    if not ok then return nil, err end
  end
  return webui_config_document(), changed
end

local function write_status(reason)
  local codec = rawget(_G, "json") or rawget(_G, "sjson")
  if not codec or not codec.encode or not file or not file.putcontents then return end
  local document = {
    version = APP.VERSION,
    reason = reason,
    running = APP.running,
    phase = S.phase,
    ready = S.ready,
    connected = S.connected,
    playing = S.playing,
    network_ip = APP.network_ip,
    system_ip = APP.system_ip,
    ip_lookup_error = APP.ip_lookup_error,
    error = S.error,
    warning = S.warning,
    core_error = APP.core_error,
    native_core = S.native_core,
    auth_available = S.auth_available,
    alac_available = S.alac_available,
    encryption_available = S.encryption_available,
    rtsp_port = APP.config.rtsp_port,
  }
  local ok, encoded = pcall(function() return codec.encode(document) end)
  if ok and type(encoded) == "string" then
    pcall(function() file.putcontents(APP.STATUS_PATH, encoded) end)
  end
end

local function runtime_document()
  local document = snapshot()
  document.running = APP.running
  document.network_ip = APP.network_ip
  document.system_ip = APP.system_ip
  document.core_error = APP.core_error
  document.rtsp_port = APP.config.rtsp_port
  document.overlay_config = webui_config_document()
  if APP.core and APP.core.state then
    local ok, audio = pcall(APP.core.state)
    if ok and type(audio) == "table" then document.audio = audio end
  end
  if APP.overlay and APP.overlay.get_state then
    local ok, overlay = pcall(APP.overlay.get_state, APP.overlay)
    if ok and type(overlay) == "table" then document.overlay = overlay end
  end
  return document
end

local function register_status_route()
  if not httpd or not httpd.dynamic or not httpd.GET then return end
  local route = "/airplay_service/status"
  pcall(function() httpd.unregister(httpd.GET, route) end)
  local ok, err = pcall(function()
    return httpd.dynamic(httpd.GET, route, function()
      local codec = rawget(_G, "json") or rawget(_G, "sjson")
      local document = runtime_document()
      document.ok = true
      local encoded = codec.encode(document)
      return {
        status = "200 OK",
        type = "application/json; charset=utf-8",
        headers = { ["cache-control"] = "no-store", ["connection"] = "close" },
        body = encoded,
      }
    end)
  end)
  if ok and not err then
    APP.status_route = route
  else
    S.warning = "status route unavailable: " .. tostring(err)
  end
end

local function unregister_webui_routes()
  if not httpd or not httpd.unregister then return end
  for i = #APP.webui_routes, 1, -1 do
    local item = APP.webui_routes[i]
    pcall(function() httpd.unregister(item.method, item.route) end)
    table.remove(APP.webui_routes, i)
  end
end

local function register_webui_route(method, route, handler)
  pcall(function() httpd.unregister(method, route) end)
  local ok, err = pcall(function() return httpd.dynamic(method, route, handler) end)
  if not ok or err then return nil, tostring(err or "httpd.dynamic failed") end
  APP.webui_routes[#APP.webui_routes + 1] = { method = method, route = route }
  return true
end

local function register_webui_routes()
  if not httpd or not httpd.dynamic or not httpd.GET or not httpd.POST then
    S.warning = "WebUI unavailable: httpd dynamic routes missing"
    return
  end
  unregister_webui_routes()
  local base = APP.WEBUI_ROUTE_BASE
  local function redirect()
    return text_response("302 Found", "text/plain; charset=utf-8", "", { ["location"] = base .. "/" })
  end
  local function index()
    local page
    if file and file.getcontents then
      local ok, body = pcall(file.getcontents, APP.WEBUI_PAGE_PATH)
      if ok and type(body) == "string" then page = body end
    end
    if not page then
      return text_response("503 Service Unavailable", "text/plain; charset=utf-8", "AirPlay WebUI page not installed")
    end
    return text_response("200 OK", "text/html; charset=utf-8", page)
  end
  local function config_get()
    return json_response("200 OK", { ok = true, config = webui_config_document(), status = runtime_document() })
  end
  local function config_post(req)
    local values = parse_query(req and req.query)
    local config, changed_or_error = APP.apply_webui_config(values, true)
    if not config then return json_response("500 Internal Server Error", { ok = false, error = changed_or_error }) end
    return json_response("200 OK", {
      ok = true, saved = true, changed = changed_or_error == true,
      config = config, status = runtime_document(),
    })
  end
  local routes = {
    { httpd.GET, base, redirect },
    { httpd.GET, base .. "/", index },
    { httpd.GET, base .. "/config", config_get },
    { httpd.POST, base .. "/config", config_post },
  }
  for _, item in ipairs(routes) do
    local ok, err = register_webui_route(item[1], item[2], item[3])
    if not ok then S.warning = "WebUI route unavailable: " .. err end
  end
end

local function set_phase(phase, err)
  S.phase = phase
  S.error = err
  S.connected = phase == "connecting" or phase == "buffering" or
                phase == "playing" or phase == "paused"
  S.playing = phase == "playing"
  notify()
  write_status("phase")
end

local function now_ms()
  if tmr and tmr.now then
    local ok, us = pcall(tmr.now)
    if ok and type(us) == "number" then return math.floor(us / 1000) end
  end
  if tmr and tmr.time then
    local ok, sec = pcall(tmr.time)
    if ok and type(sec) == "number" then return sec * 1000 end
  end
  return 0
end

local function elapsed_ms(now, before)
  local d = now - before
  if d < -1000000 then d = d + 4294967 end
  return d
end

local function u16be(n)
  n = math.floor(tonumber(n) or 0) % 65536
  return string.char(math.floor(n / 256), n % 256)
end

local function u32be(n)
  n = math.floor(tonumber(n) or 0) % 4294967296
  local a = math.floor(n / 16777216) % 256
  local b = math.floor(n / 65536) % 256
  local c = math.floor(n / 256) % 256
  return string.char(a, b, c, n % 256)
end

local function read_u16(s, p)
  local a, b = s:byte(p, p + 1)
  if not a or not b then return nil end
  return a * 256 + b
end

local function read_u32(s, p)
  local a, b, c, d = s:byte(p, p + 3)
  if not a or not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function safe_close(obj)
  if not obj then return end
  pcall(function()
    if obj.on then
      obj:on("receive", nil)
      obj:on("sent", nil)
      obj:on("disconnection", nil)
    end
  end)
  pcall(function() obj:close() end)
end

local function stop_timer(timer)
  if not timer then return end
  pcall(function() timer:unregister() end)
end

local function add_timer(ms, mode, fn)
  local timer = tmr.create()
  timer:alarm(ms, mode, fn)
  APP.timers[#APP.timers + 1] = timer
  return timer
end

local function refresh_overlay()
  if not APP.running or not APP.overlay_dirty then return end
  local started = now_ms()
  -- The WebUI refresh option controls how quickly changes are noticed.  The
  -- actual transparent-canvas redraw is separately bounded because a CJK
  -- redraw can take hundreds of milliseconds on firmware 1.200.
  local interval = math.max(
    tonumber(APP.config.overlay_refresh_ms) or 100,
    tonumber(APP.config.overlay_min_render_interval_ms) or 1000
  )
  if APP.overlay_last_run_ms and elapsed_ms(started, APP.overlay_last_run_ms) < interval then return end
  APP.overlay_dirty = false
  if not APP.overlay or not APP.overlay.update then return end
  local ok, err = pcall(APP.overlay.update, APP.overlay, S)
  local finished = now_ms()
  APP.overlay_last_run_ms = finished
  local render_ms = math.max(0, elapsed_ms(finished, started))
  S.last_overlay_update_ms = finished
  S.last_overlay_render_ms = render_ms
  S.max_overlay_render_ms = math.max(S.max_overlay_render_ms or 0, render_ms)
  S.metrics.overlay_updates = S.metrics.overlay_updates + 1
  if not ok then
    S.overlay_error = tostring(err)
    S.metrics.overlay_errors = S.metrics.overlay_errors + 1
  else
    S.overlay_error = nil
  end
end

local function clean_name(value)
  value = tostring(value or "HoloCubic")
  value = value:gsub("[\r\n]", " "):gsub("%.", "-")
  if #value > 48 then value = value:sub(1, 48) end
  if value == "" then value = "HoloCubic" end
  return value
end

local function normalize_mac(mac)
  local compact = tostring(mac or ""):gsub("[^%x]", ""):upper()
  if #compact < 12 then compact = (compact .. "020000000001"):sub(1, 12) end
  return compact:sub(1, 12)
end

local function current_ip()
  local configured_ip = tostring(APP.config.ip or "")
  if configured_ip:match("^%d+%.%d+%.%d+%.%d+$") and configured_ip ~= "0.0.0.0" then
    return configured_ip
  end
  local function from(getter)
    if type(getter) ~= "function" then return nil end
    local ok, ip = pcall(getter)
    if ok and type(ip) == "string" and ip ~= "" and ip ~= "0.0.0.0" then return ip end
    return nil
  end
  local ip = wifi and wifi.sta and from(wifi.sta.getip)
  if ip then return ip end
  ip = wifi and wifi.ap and from(wifi.ap.getip) or nil
  if ip then return ip end
  return APP.system_ip
end

local function refresh_system_ip(force)
  if APP.config.ip or APP.ip_lookup_pending or not http or not http.get then return end
  local now = now_ms()
  if not force and APP.ip_lookup_ms ~= 0 and elapsed_ms(now, APP.ip_lookup_ms) < 30000 then return end
  APP.ip_lookup_pending = true
  APP.ip_lookup_ms = now
  local call_ok, call_error = pcall(function()
    http.get("http://127.0.0.1/api/system/state", { timeout = 1500 }, function(code, body)
      APP.ip_lookup_pending = false
      if not APP.running then return end
      if tonumber(code) ~= 200 or type(body) ~= "string" then
        APP.ip_lookup_error = "system state HTTP " .. tostring(code)
        write_status("ip-lookup")
        return
      end
      local codec = rawget(_G, "json") or rawget(_G, "sjson")
      local ok, document = pcall(function() return codec.decode(body) end)
      local network = ok and type(document) == "table" and document.wifi or nil
      local ip = network and network.sta_connected and network.sta_ip or (network and network.ap_ip)
      if type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") and ip ~= "0.0.0.0" then
        APP.system_ip = ip
        APP.ip_lookup_error = nil
      else
        APP.ip_lookup_error = "system state has no usable IP"
      end
      write_status("ip-lookup")
    end)
  end)
  if not call_ok then
    APP.ip_lookup_pending = false
    APP.ip_lookup_error = tostring(call_error)
    write_status("ip-lookup")
  end
end

local function current_mac()
  if wifi and wifi.sta and wifi.sta.getmac then
    local ok, mac = pcall(wifi.sta.getmac)
    if ok then return normalize_mac(mac) end
  end
  return "020000000001"
end

-- Minimal DNS-SD encoder.  Unsolicited multicast responses make the service
-- discoverable even on firmware builds whose Lua UDP API cannot join a group.
local function dns_name(name)
  local out = {}
  for source_label in tostring(name):gmatch("([^.]+)") do
    local label = source_label
    if #label > 63 then label = label:sub(1, 63) end
    out[#out + 1] = string.char(#label) .. label
  end
  out[#out + 1] = "\0"
  return table.concat(out)
end

local function dns_rr(name, typ, class, ttl, rdata)
  return dns_name(name) .. u16be(typ) .. u16be(class) .. u32be(ttl) ..
         u16be(#rdata) .. rdata
end

local function ipv4_bytes(ip)
  local out = {}
  for text in tostring(ip):gmatch("(%d+)") do
    local n = tonumber(text)
    if not n or n < 0 or n > 255 then return nil end
    out[#out + 1] = n
  end
  if #out ~= 4 then return nil end
  return string.char(out[1], out[2], out[3], out[4])
end

local function txt_rdata(items)
  local out = {}
  for _, value in ipairs(items) do
    local item = tostring(value)
    if #item > 255 then item = item:sub(1, 255) end
    out[#out + 1] = string.char(#item) .. item
  end
  return table.concat(out)
end

local function mdns_packet(ttl)
  local mac = current_mac()
  local instance = mac .. "@" .. clean_name(APP.config.name) .. "._raop._tcp.local"
  local host = "holocubic-" .. mac:sub(7):lower() .. ".local"
  local service = "_raop._tcp.local"
  local ip = APP.network_ip or current_ip() or "0.0.0.0"
  local address = ipv4_bytes(ip) or "\0\0\0\0"
  local codecs = S.alac_available and "cn=0,1" or "cn=0"
  local encryption = S.encryption_available and "et=0,1" or "et=0"
  local txt_items = {
    "txtvers=1", "ch=2", codecs, encryption, "sv=false", "da=true",
    "sr=44100", "ss=16", "tp=UDP", "vn=3", "md=0,1,2",
    "pw=false", "am=HoloCubic", "fv=" .. APP.VERSION, "sf=0x4",
  }
  if S.auth_available then txt_items[#txt_items + 1] = "ek=1" end
  local txt = txt_rdata(txt_items)
  local answers = {
    dns_rr(service, 12, 1, ttl, dns_name(instance)),
    dns_rr(instance, 33, 0x8001, ttl,
      u16be(0) .. u16be(0) .. u16be(APP.config.rtsp_port) .. dns_name(host)),
    dns_rr(instance, 16, 0x8001, ttl, txt),
    dns_rr(host, 1, 0x8001, ttl, address),
  }
  return u16be(0) .. u16be(0x8400) .. u16be(0) .. u16be(#answers) ..
         u16be(0) .. u16be(0) .. table.concat(answers)
end

local function send_mdns(ttl)
  if not APP.mdns_socket then return end
  local packet = mdns_packet(ttl or 120)
  pcall(function() APP.mdns_socket:send(5353, "224.0.0.251", packet) end)
end

local function parse_transport(value)
  local out = {}
  for item in tostring(value or ""):gmatch("[^;]+") do
    local key, val = item:match("^%s*([^=]+)=?(.-)%s*$")
    if key then out[key:lower()] = val ~= "" and val or true end
  end
  return out
end

local function parse_sdp(body)
  local out = { codec = nil, sample_rate = 44100, channels = 2 }
  for line in tostring(body or ""):gmatch("[^\r\n]+") do
    local payload, encoding, rate, channels = line:match(
      "^a=rtpmap:(%d+)%s+([^/]+)/?(%d*)/?(%d*)")
    if payload then
      out.payload_type = tonumber(payload)
      local lower = encoding:lower()
      if lower == "applelossless" then out.codec = "alac"
      elseif lower == "l16" then out.codec = "l16"
      else out.codec = lower end
      out.sample_rate = tonumber(rate) or out.sample_rate
      out.channels = tonumber(channels) or out.channels
    end
    local fmtp = line:match("^a=fmtp:%d+%s+(.+)$")
    if fmtp then out.fmtp = fmtp end
    local aes_key = line:match("^a=rsaaeskey:(.+)$")
    if aes_key then out.rsaaeskey = aes_key end
    local aes_iv = line:match("^a=aesiv:(.+)$")
    if aes_iv then out.aesiv = aes_iv end
  end
  if not out.codec then
    if out.fmtp then out.codec = "alac" else out.codec = "l16" end
  end
  return out
end

local dmap_containers = {
  cmst = true, mlit = true, mdcl = true, msrv = true, caps = true,
}

local dmap_fields = {
  minm = "title",
  asar = "artist",
  asal = "album",
  asgn = "genre",
  ascp = "composer",
}

local function parse_dmap_into(data, first, last, result, depth)
  local p = first or 1
  last = last or #data
  depth = depth or 0
  if depth > 8 then return end
  while p + 7 <= last do
    local tag = data:sub(p, p + 3)
    local len = read_u32(data, p + 4)
    if not len or len < 0 then return end
    local value_start = p + 8
    local value_end = value_start + len - 1
    if value_end > last then return end
    if dmap_containers[tag] then
      parse_dmap_into(data, value_start, value_end, result, depth + 1)
    elseif dmap_fields[tag] then
      result[dmap_fields[tag]] = data:sub(value_start, value_end)
    end
    p = value_end + 1
  end
end

local function parse_dmap(data)
  local out = {}
  parse_dmap_into(data or "", 1, #(data or ""), out, 0)
  return out
end

local function reset_metadata()
  S.title, S.artist, S.album = "", "", ""
  S.artwork_mime, S.artwork_bytes = nil, 0
  S.position_ms, S.duration_ms = 0, 0
end

local function reset_metrics()
  for key in pairs(S.metrics) do S.metrics[key] = 0 end
  S.last_rtsp_response_method = nil
  S.last_rtsp_response_code = nil
  S.last_rtsp_response_queued_ms = nil
  S.last_rtsp_response_sent_ms = nil
  S.last_rtsp_send_error = nil
  S.last_disconnect_pending_responses = 0
  S.last_disconnect_pending_methods = ""
  S.last_rtsp_response_latency_ms = 0
  S.max_rtsp_response_latency_ms = 0
  S.last_overlay_update_ms = nil
  S.last_overlay_render_ms = 0
  S.max_overlay_render_ms = 0
  S.overlay_error = nil
  S.last_timing_response_ms = nil
  S.last_timing_roundtrip_ms = nil
  S.last_sync_ms = nil
  S.sync_rtp_timestamp = nil
  S.sync_latency_frames = nil
end

local function new_jitter()
  return {
    packets = {}, count = 0, expected = nil, first_seq = nil,
    missing_ticks = 0, last_pcm_size = 1408, next_write_ms = nil,
  }
end

APP.jitter = new_jitter()

local function seq_distance(a, b)
  return ((a - b + 32768) % 65536) - 32768
end

local function parse_rtp(packet)
  if type(packet) ~= "string" or #packet < 12 then return nil, "short RTP packet" end
  local b1, b2 = packet:byte(1, 2)
  if math.floor(b1 / 64) ~= 2 then return nil, "not RTP v2" end
  local cc = b1 & 0x0f
  local p = 13 + cc * 4
  if (b1 & 0x10) ~= 0 then
    local words = read_u16(packet, p + 2)
    if not words then return nil, "bad RTP extension" end
    p = p + 4 + words * 4
  end
  if p > #packet + 1 then return nil, "bad RTP header" end
  return {
    marker = (b2 & 0x80) ~= 0,
    payload_type = b2 & 0x7f,
    seq = read_u16(packet, 3),
    timestamp = read_u32(packet, 5),
    payload = packet:sub(p),
  }
end

local function l16_to_pcm(payload, channels)
  local out = {}
  local left_peak, right_peak = 0, 0
  local channel = 1
  local volume_db = tonumber(S.volume_db) or 0
  local gain = volume_db <= -144 and 0 or math.min(1, 10 ^ (volume_db / 20))
  local n = #payload - (#payload % 2)
  for p = 1, n, 2 do
    local hi, lo = payload:byte(p, p + 1)
    local sample = hi * 256 + lo
    if sample >= 32768 then sample = sample - 65536 end
    local scaled = sample * gain
    sample = scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
    if sample > 32767 then sample = 32767 elseif sample < -32768 then sample = -32768 end
    local encoded = sample < 0 and sample + 65536 or sample
    out[#out + 1] = string.char(encoded % 256, math.floor(encoded / 256))
    local magnitude = math.abs(sample)
    if channel == 1 then
      if magnitude > left_peak then left_peak = magnitude end
    else
      if magnitude > right_peak then right_peak = magnitude end
    end
    channel = channel + 1
    if channel > channels then channel = 1 end
  end
  if channels == 1 then right_peak = left_peak end
  return table.concat(out), left_peak / 32768, right_peak / 32768
end

local function clear_jitter()
  APP.jitter = new_jitter()
  if APP.core and APP.core.flush then pcall(APP.core.flush) end
end

local function send_resend(seq, count)
  if APP.native_udp then return true end
  local session = APP.session
  if not APP.control_socket or not session or not session.client_ip or
     not session.client_control_port then return false end
  session.resend_seq = ((session.resend_seq or 0) + 1) % 65536
  local packet = string.char(0x80, 0xd5) .. u16be(session.resend_seq) ..
                 u16be(seq) .. u16be(count or 1)
  local ok = pcall(function()
    APP.control_socket:send(session.client_control_port, session.client_ip, packet)
  end)
  if ok then S.metrics.resend_requests = S.metrics.resend_requests + 1 end
  return ok
end

local function queue_rtp(packet, source_ip)
  if source_ip and APP.session and APP.session.client_ip ~= source_ip then
    APP.session.client_ip = source_ip
    S.client_ip = source_ip
  end
  if APP.core and APP.core.ingest_rtp then
    local resend_sequence, resend_count, resend_serial =
      APP.core.ingest_rtp(packet, tonumber(APP.core_resend_serial) or 0)
    resend_serial = tonumber(resend_serial)
    if resend_serial and resend_serial ~= APP.core_resend_serial and
       resend_sequence and send_resend(tonumber(resend_sequence),
                                       tonumber(resend_count) or 1) then
      APP.core_resend_serial = resend_serial
    end
    return
  end
  S.metrics.bytes_received = S.metrics.bytes_received + #packet
  if APP.core and APP.core.push_rtp then
    local ok, accepted, err = pcall(APP.core.push_rtp, packet)
    if not ok or accepted == false or accepted == nil then
      S.metrics.rtp_dropped = S.metrics.rtp_dropped + 1
      S.warning = tostring(err or accepted or "native RTP push failed")
    else
      S.metrics.rtp_received = S.metrics.rtp_received + 1
    end
    return
  end

  local rtp, err = parse_rtp(packet)
  if not rtp then
    S.metrics.rtp_dropped = S.metrics.rtp_dropped + 1
    S.warning = err
    return
  end
  if not APP.session or APP.session.codec ~= "l16" then
    S.metrics.rtp_dropped = S.metrics.rtp_dropped + 1
    return
  end
  if APP.session.payload_type and rtp.payload_type ~= APP.session.payload_type then
    S.metrics.rtp_dropped = S.metrics.rtp_dropped + 1
    return
  end

  local j = APP.jitter
  if j.expected and seq_distance(rtp.seq, j.expected) < 0 then
    S.metrics.rtp_late = S.metrics.rtp_late + 1
    return
  end
  if j.packets[rtp.seq] then return end
  if j.count >= APP.config.max_jitter_packets then
    S.metrics.rtp_dropped = S.metrics.rtp_dropped + 1
    return
  end
  local pcm, left, right = l16_to_pcm(rtp.payload, APP.session.channels or 2)
  j.packets[rtp.seq] = { pcm = pcm, timestamp = rtp.timestamp, left = left, right = right }
  j.count = j.count + 1
  if not j.first_seq then j.first_seq = rtp.seq end
  S.metrics.rtp_received = S.metrics.rtp_received + 1
end

local function claim_audio_focus()
  S.focus_conflict = false
  if APP.audio_focus_handler then
    local ok, accepted, reason = pcall(APP.audio_focus_handler, "airplay")
    if not ok or accepted == false then
      S.focus_conflict = true
      return nil, tostring(reason or accepted or "audio focus handler failed")
    end
  else
    local player = rawget(_G, "MUSIC_PLAYER_APP")
    if player and player.state and player.state.playing then
      S.focus_conflict = true
      return nil, "local music is playing; no audio-focus handler is installed"
    end
  end
  return true
end

local function start_output()
  if APP.output_owned then return true end
  local ok_focus, focus_err = claim_audio_focus()
  if not ok_focus then return nil, focus_err end
  local session = APP.session or {}
  if APP.core and APP.core.start then
    local ok, started, err = pcall(APP.core.start, {
      i2s_port = APP.config.i2s_port,
      data_out_pin = APP.config.data_out_pin,
      sample_rate = session.sample_rate or APP.config.sample_rate,
      channels = session.channels or APP.config.channels,
      output_channels = APP.config.output_channels,
      bits = 16,
      buffer_count = APP.config.dma_buffer_count,
      buffer_len = APP.config.dma_buffer_len,
      prebuffer_packets = APP.config.prebuffer_packets,
      missing_wait_ticks = APP.config.missing_wait_ticks,
      task_priority = APP.config.audio_task_priority,
      task_core = APP.config.audio_task_core,
      output_core = APP.config.output_task_core,
    })
    if not ok or not started then return nil, tostring(err or started) end
    APP.output_owned = true
    return true
  end
  if session.codec ~= "l16" then return nil, "ALAC requires airplay_core.so" end
  if not i2s or not i2s.start then return nil, "firmware has no i2s API" end
  pcall(i2s.stop, APP.config.i2s_port)
  local channel = i2s.CHANNEL_RIGHT_LEFT or i2s.CHANNEL_ALL_LEFT or i2s.CHANNEL_ONLY_LEFT
  local ok, err = pcall(i2s.start, APP.config.i2s_port, {
    mode = i2s.MODE_MASTER | i2s.MODE_TX,
    rate = session.sample_rate or APP.config.sample_rate,
    bits = 16,
    channel = channel,
    format = i2s.FORMAT_I2S,
    buffer_count = APP.config.dma_buffer_count,
    buffer_len = APP.config.dma_buffer_len,
    data_out_pin = APP.config.data_out_pin,
  })
  if not ok then return nil, tostring(err) end
  APP.output_owned = true
  return true
end

local function stop_output()
  if APP.core and APP.core.stop then pcall(APP.core.stop) end
  if APP.output_owned and (not APP.core) and i2s and i2s.stop then
    pcall(i2s.stop, APP.config.i2s_port)
  end
  APP.output_owned = false
  clear_jitter()
  S.level_left, S.level_right = 0, 0
end

local function drain_audio()
  if not APP.running or not APP.output_owned then return end
  if APP.core then
    if APP.core.poll then
      local left, right, playing, resend_serial, resend_sequence, resend_count = APP.core.poll()
      S.level_left = tonumber(left) or S.level_left
      S.level_right = tonumber(right) or S.level_right
      resend_serial = tonumber(resend_serial)
      if resend_serial and resend_serial ~= APP.core_resend_serial then
        if resend_serial > 0 and resend_sequence then
          if send_resend(tonumber(resend_sequence), tonumber(resend_count) or 1) then
            APP.core_resend_serial = resend_serial
          end
        else
          APP.core_resend_serial = resend_serial
        end
      end
      if playing and S.phase ~= "playing" then set_phase("playing") end
    elseif APP.core.state then
      local ok, value = pcall(APP.core.state)
      if ok and type(value) == "table" then
        S.level_left = tonumber(value.left) or S.level_left
        S.level_right = tonumber(value.right) or S.level_right
        local resend_serial = tonumber(value.resend_serial)
        if resend_serial and resend_serial ~= APP.core_resend_serial then
          if resend_serial > 0 and value.resend_sequence then
            if send_resend(tonumber(value.resend_sequence), tonumber(value.resend_count) or 1) then
              APP.core_resend_serial = resend_serial
            end
          else
            APP.core_resend_serial = resend_serial
          end
        end
        if value.playing and S.phase ~= "playing" then set_phase("playing") end
      end
    end
    return
  end
  local j = APP.jitter
  if not j.expected then
    if j.count < APP.config.prebuffer_packets or not j.first_seq then return end
    j.expected = j.first_seq
    j.next_write_ms = now_ms()
    set_phase("playing")
  end
  local now = now_ms()
  if j.next_write_ms and elapsed_ms(now, j.next_write_ms) < 0 then return end
  local item = j.packets[j.expected]
  if not item then
    j.missing_ticks = j.missing_ticks + 1
    if j.missing_ticks == 1 then send_resend(j.expected, 1) end
    if j.missing_ticks <= APP.config.missing_wait_ticks then return end
    S.metrics.rtp_lost = S.metrics.rtp_lost + 1
    item = { pcm = string.rep("\0", j.last_pcm_size), left = 0, right = 0 }
  else
    j.packets[j.expected] = nil
    j.count = j.count - 1
  end
  j.missing_ticks = 0
  j.expected = (j.expected + 1) % 65536
  if #item.pcm > 0 then
    local ok, err = pcall(i2s.write, APP.config.i2s_port, item.pcm)
    if not ok then
      set_phase("error", "i2s.write failed: " .. tostring(err))
      stop_output()
      return
    end
    j.last_pcm_size = #item.pcm
    S.metrics.rtp_written = S.metrics.rtp_written + 1
    S.level_left = item.left or 0
    S.level_right = item.right or 0
    local channels = APP.session and APP.session.channels or 2
    local rate = APP.session and APP.session.sample_rate or 44100
    local frames = #item.pcm / (2 * channels)
    local duration = math.max(1, math.floor(frames * 1000 / rate + 0.5))
    j.next_write_ms = now + duration
  end
end

local function reset_session(reason)
  stop_output()
  if APP.native_udp and APP.core and APP.core.network_clear_peer then
    pcall(APP.core.network_clear_peer)
  end
  if reason ~= "network stopped" then
    S.last_session_end = reason
    S.last_session_end_ms = now_ms()
  end
  APP.session = nil
  APP.active_ctx = nil
  S.client_ip, S.session_id, S.codec = nil, nil, nil
  S.focus_conflict = false
  if reason ~= "network stopped" then set_phase(S.ready and "advertising" or "starting") end
end

local function native_capabilities()
  if not APP.core then return end
  S.native_core = true
  local caps = nil
  if APP.core.capabilities then
    local ok, value = pcall(APP.core.capabilities)
    if ok and type(value) == "table" then caps = value end
  end
  S.auth_available = caps and caps.apple_challenge == true or APP.core.apple_response ~= nil
  S.encryption_available = caps and caps.aes == true or false
  S.alac_available = caps and caps.alac == true or false
  APP.native_udp_available = caps and caps.native_socket_abi == true and
                             APP.core.network_start ~= nil
end

local function load_native_core()
  local ok, core = pcall(require, APP.MODULE_PATH)
  if ok and type(core) == "table" then
    APP.core = core
    native_capabilities()
    log("native core loaded")
  else
    APP.core_error = tostring(core)
    S.warning = "PCM-only mode; native ALAC/RSA core is not installed"
    log("native core unavailable", APP.core_error)
  end
  write_status("native-core")
end

local function common_headers(ctx, request)
  local headers = {
    ["Server"] = "AirTunes/105.1",
    ["Audio-Jack-Status"] = "connected; type=analog",
  }
  local cseq = request.headers["cseq"]
  if cseq then headers["CSeq"] = cseq end
  if ctx.session_id then headers["Session"] = ctx.session_id end
  local challenge = request.headers["apple-challenge"]
  if challenge then
    if APP.core and APP.core.apple_response then
      local ok, response = pcall(APP.core.apple_response, challenge, APP.network_ip, current_mac())
      if ok and response then headers["Apple-Response"] = response
      else S.warning = "Apple-Challenge response failed: " .. tostring(response) end
    else
      S.warning = "sender requested Apple-Challenge, but native RSA core is unavailable"
    end
  end
  return headers
end

local reason_phrases = {
  [200] = "OK", [400] = "Bad Request", [405] = "Method Not Allowed",
  [415] = "Unsupported Media Type", [453] = "Not Enough Bandwidth",
  [454] = "Session Not Found", [500] = "Internal Server Error",
}

local function finish_response(ctx, item)
  ctx.sending_response = false
  ctx.current_response = nil
  local sent_ms = now_ms()
  local latency_ms = item.queued_ms and math.max(0, elapsed_ms(sent_ms, item.queued_ms)) or 0
  S.metrics.rtsp_responses_sent = S.metrics.rtsp_responses_sent + 1
  if latency_ms > 250 then
    S.metrics.rtsp_response_over_250ms = S.metrics.rtsp_response_over_250ms + 1
  end
  if latency_ms > 1000 then
    S.metrics.rtsp_response_over_1000ms = S.metrics.rtsp_response_over_1000ms + 1
  end
  S.last_rtsp_response_method = item.method
  S.last_rtsp_response_code = item.code
  S.last_rtsp_response_sent_ms = sent_ms
  S.last_rtsp_response_latency_ms = latency_ms
  S.max_rtsp_response_latency_ms = math.max(S.max_rtsp_response_latency_ms or 0, latency_ms)
  return item.after_send
end

local function pump_response(ctx)
  if ctx.closed or ctx.sending_response or not ctx.response_queue or
     #ctx.response_queue == 0 then return end
  local item = table.remove(ctx.response_queue, 1)
  ctx.sending_response = true
  ctx.current_response = item
  local ok, err = pcall(function() ctx.socket:send(item.data) end)
  if ok then return end

  ctx.sending_response = false
  ctx.current_response = nil
  S.metrics.rtsp_send_errors = S.metrics.rtsp_send_errors + 1
  S.last_rtsp_send_error = tostring(err)
  if item.after_send then pcall(item.after_send) end
  ctx.closed = true
  APP.clients[ctx.socket] = nil
  safe_close(ctx.socket)
  if APP.session and ctx.session_id == S.session_id then reset_session("send error") end
end

local function send_response(ctx, request, code, headers, body, after_send)
  headers = headers or {}
  body = body or ""
  local base = common_headers(ctx, request)
  for k, v in pairs(headers) do base[k] = v end
  if #body > 0 then base["Content-Length"] = #body end
  local lines = { "RTSP/1.0 " .. code .. " " .. (reason_phrases[code] or "Error") }
  for k, v in pairs(base) do lines[#lines + 1] = k .. ": " .. tostring(v) end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  local response = table.concat(lines, "\r\n")
  ctx.response_queue = ctx.response_queue or {}
  if #ctx.response_queue >= 64 then
    S.metrics.rtsp_send_errors = S.metrics.rtsp_send_errors + 1
    S.last_rtsp_send_error = "RTSP response queue full"
    ctx.closed = true
    APP.clients[ctx.socket] = nil
    safe_close(ctx.socket)
    if APP.session and ctx.session_id == S.session_id then reset_session("send queue full") end
    return
  end
  ctx.response_queue[#ctx.response_queue + 1] = {
    data = response,
    after_send = after_send,
    method = request.method or "UNKNOWN",
    code = code,
    queued_ms = now_ms(),
  }
  S.metrics.rtsp_responses_queued = S.metrics.rtsp_responses_queued + 1
  S.last_rtsp_response_queued_ms = now_ms()
  pump_response(ctx)
end

local function parse_text_parameters(body)
  local out = {}
  for line in tostring(body or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
    if key then out[key:lower()] = value end
  end
  return out
end

local function apply_metadata(request)
  local content_type = (request.headers["content-type"] or ""):lower()
  if content_type:find("application/x%-dmap%-tagged") then
    local metadata = parse_dmap(request.body)
    if metadata.title then S.title = metadata.title end
    if metadata.artist then S.artist = metadata.artist end
    if metadata.album then S.album = metadata.album end
    notify()
  elseif content_type:find("image/") then
    S.artwork_mime = content_type:match("^(image/[^;]+)")
    S.artwork_bytes = #request.body
    notify()
  else
    local values = parse_text_parameters(request.body)
    if values.volume then
      S.volume_db = tonumber(values.volume) or S.volume_db
      if APP.core and APP.core.set_volume then
        local gain = S.volume_db <= -144 and 0 or math.min(1, 10 ^ (S.volume_db / 20))
        pcall(APP.core.set_volume, S.volume_db, gain)
      end
    end
    if values.progress then
      local start, current, finish = values.progress:match("(%d+)/(%d+)/(%d+)")
      start, current, finish = tonumber(start), tonumber(current), tonumber(finish)
      local rate = APP.session and APP.session.sample_rate or 44100
      if start and current and finish and rate > 0 then
        S.position_ms = math.max(0, math.floor((current - start) * 1000 / rate))
        S.duration_ms = math.max(0, math.floor((finish - start) * 1000 / rate))
      end
    end
    notify()
  end
end

local function configure_session(sdp)
  if sdp.codec == "alac" then
    if not APP.core or not S.alac_available or not APP.core.configure then
      return nil, "Apple Lossless requires native airplay_core.so"
    end
    local ok, configured_ok, err = pcall(APP.core.configure, {
      codec = "alac", fmtp = sdp.fmtp, rsaaeskey = sdp.rsaaeskey,
      aesiv = sdp.aesiv, payload_type = sdp.payload_type,
      sample_rate = sdp.sample_rate, channels = sdp.channels,
    })
    if not ok or not configured_ok then return nil, tostring(err or configured_ok) end
  elseif sdp.codec == "l16" then
    if APP.core and APP.core.configure then
      local ok, configured_ok, err = pcall(APP.core.configure, {
        codec = "l16", payload_type = sdp.payload_type,
        sample_rate = sdp.sample_rate, channels = sdp.channels,
      })
      if not ok or not configured_ok then return nil, tostring(err or configured_ok) end
    end
  else
    return nil, "unsupported codec: " .. tostring(sdp.codec)
  end
  APP.session = sdp
  APP.session.client_ip = S.client_ip
  S.codec = sdp.codec
  S.sample_rate = sdp.sample_rate
  S.channels = sdp.channels
  APP.core_resend_serial = 0
  clear_jitter()
  return true
end

local function handle_rtsp(ctx, request)
  S.metrics.rtsp_requests = S.metrics.rtsp_requests + 1
  local method = request.method
  ctx.last_method = method
  S.last_rtsp_method = method
  S.last_rtsp_ms = now_ms()
  log(method, request.uri)

  if method == "OPTIONS" then
    send_response(ctx, request, 200, {
      ["Public"] = "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER",
    })
    return
  end

  if method == "ANNOUNCE" then
    if APP.active_ctx and APP.active_ctx ~= ctx and APP.session then
      send_response(ctx, request, 453, { ["X-AirPlay-Error"] = "another sender is active" })
      return
    end
    if ctx.peer_ip then S.client_ip = ctx.peer_ip end
    local sdp = parse_sdp(request.body)
    local ok, err = configure_session(sdp)
    if not ok then
      set_phase("error", err)
      send_response(ctx, request, 415, { ["X-AirPlay-Error"] = err })
      return
    end
    reset_metadata()
    reset_metrics()
    ctx.session_id = tostring(math.floor(now_ms())) .. tostring(math.random(1000, 9999))
    APP.active_ctx = ctx
    S.session_id = ctx.session_id
    set_phase("connecting")
    send_response(ctx, request, 200)
    return
  end

  if method == "SETUP" then
    if not APP.session then send_response(ctx, request, 454) return end
    local transport = parse_transport(request.headers["transport"])
    APP.session.client_control_port = tonumber(transport.control_port)
    APP.session.client_timing_port = tonumber(transport.timing_port)
    APP.session.timing_request_count = 0
    APP.session.last_timing_request_ms = nil
    APP.session.timing_active = false
    if APP.native_udp and APP.core and APP.core.network_set_peer then
      local peer_ip = APP.session.client_ip or ctx.peer_ip or S.client_ip
      local peer_ok, configured, peer_err = pcall(APP.core.network_set_peer, {
        ip = peer_ip,
        control_port = APP.session.client_control_port,
        timing_port = APP.session.client_timing_port,
      })
      if not peer_ok or not configured then
        S.warning = "native UDP peer setup failed: " .. tostring(peer_ok and peer_err or configured)
      end
    end
    send_response(ctx, request, 200, {
      ["Transport"] = "RTP/AVP/UDP;unicast;mode=record;server_port=" .. APP.config.audio_port ..
        ";control_port=" .. APP.config.control_port .. ";timing_port=" .. APP.config.timing_port,
      ["Session"] = ctx.session_id or S.session_id or "1",
    })
    return
  end

  if method == "RECORD" then
    if not APP.session then send_response(ctx, request, 454) return end
    local ok, err = start_output()
    if not ok then
      set_phase("error", err)
      send_response(ctx, request, 453, { ["X-AirPlay-Error"] = err })
      return
    end
    APP.session.timing_active = true
    if APP.native_udp and APP.core and APP.core.network_set_timing then
      pcall(APP.core.network_set_timing, true)
    end
    set_phase("buffering")
    send_response(ctx, request, 200, { ["Audio-Latency"] = "11025" })
    return
  end

  if method == "SET_PARAMETER" then
    -- The sender treats metadata/progress calls as control keepalives.  Finish
    -- the RTSP response before parsing metadata or touching the overlay so a
    -- busy foreground UI cannot make iOS time out the control connection.
    send_response(ctx, request, 200, nil, nil, function()
      apply_metadata(request)
    end)
    return
  end

  if method == "GET_PARAMETER" then
    local wanted = parse_text_parameters(request.body)
    local lines = {}
    if wanted.volume ~= nil or request.body:find("volume", 1, true) then
      lines[#lines + 1] = "volume: " .. tostring(S.volume_db)
    end
    send_response(ctx, request, 200, { ["Content-Type"] = "text/parameters" },
      #lines > 0 and (table.concat(lines, "\r\n") .. "\r\n") or "")
    return
  end

  if method == "FLUSH" then
    clear_jitter()
    set_phase(APP.output_owned and "buffering" or "paused")
    send_response(ctx, request, 200)
    return
  end

  if method == "PAUSE" then
    if APP.native_udp and APP.core and APP.core.network_set_timing then
      pcall(APP.core.network_set_timing, false)
    end
    stop_output()
    set_phase("paused")
    send_response(ctx, request, 200)
    return
  end

  if method == "TEARDOWN" then
    send_response(ctx, request, 200, nil, nil, function()
      ctx.closed = true
      APP.clients[ctx.socket] = nil
      reset_session("teardown")
      safe_close(ctx.socket)
    end)
    return
  end

  send_response(ctx, request, 405)
end

local function parse_request(buffer)
  local header_end = buffer:find("\r\n\r\n", 1, true)
  if not header_end then return nil, buffer end
  local head = buffer:sub(1, header_end - 1)
  local lines = {}
  for line in head:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
  local method, uri, version = (lines[1] or ""):match("^(%S+)%s+(%S+)%s+RTSP/(%d%.%d)$")
  if not method then return false, buffer:sub(header_end + 4), "bad RTSP request line" end
  local headers = {}
  for i = 2, #lines do
    local key, value = lines[i]:match("^([^:]+):%s*(.*)$")
    if key then headers[key:lower()] = value end
  end
  local length = tonumber(headers["content-length"] or "0") or 0
  if length < 0 or length > 1024 * 1024 then
    return false, buffer:sub(header_end + 4), "invalid RTSP body length"
  end
  local body_start = header_end + 4
  local body_end = body_start + length - 1
  if #buffer < body_end then return nil, buffer end
  return {
    method = method:upper(), uri = uri, version = version,
    headers = headers,
    body = length > 0 and buffer:sub(body_start, body_end) or "",
  }, buffer:sub(body_end + 1)
end

local function on_tcp_receive(ctx, data)
  if type(data) ~= "string" then return end
  ctx.buffer = (ctx.buffer or "") .. data
  if #ctx.buffer > 1024 * 1024 + 8192 then
    safe_close(ctx.socket)
    return
  end
  while #ctx.buffer > 0 do
    if ctx.buffer:byte(1) == 0x24 then
      if #ctx.buffer < 4 then return end
      local length = read_u16(ctx.buffer, 3)
      if #ctx.buffer < length + 4 then return end
      queue_rtp(ctx.buffer:sub(5, 4 + length), S.client_ip)
      ctx.buffer = ctx.buffer:sub(5 + length)
    else
      local request, rest, err = parse_request(ctx.buffer)
      if request == nil then return end
      ctx.buffer = rest or ""
      if request == false then
        send_response(ctx, { headers = {} }, 400, { ["X-AirPlay-Error"] = err })
      else
        handle_rtsp(ctx, request)
      end
    end
  end
end

local function on_connection(socket)
  local ctx = {
    socket = socket,
    buffer = "",
    response_queue = {},
    sending_response = false,
    current_response = nil,
    closed = false,
  }
  if socket.getpeer then
    local ok, _, peer_ip = pcall(function() return socket:getpeer() end)
    if ok and type(peer_ip) == "string" then ctx.peer_ip = peer_ip end
  end
  APP.clients[socket] = ctx
  socket:on("sent", function()
    if ctx.closed or not ctx.sending_response or not ctx.current_response then return end
    local item = ctx.current_response
    local after_send = finish_response(ctx, item)
    -- Start the next queued write before any metadata/subscriber work.  This
    -- preserves response ordering while keeping pipelined control traffic out
    -- of application callbacks.
    pump_response(ctx)
    if after_send then pcall(after_send) end
  end)
  socket:on("receive", function(_, data) on_tcp_receive(ctx, data) end)
  socket:on("disconnection", function()
    ctx.closed = true
    local pending = #(ctx.response_queue or {}) + (ctx.current_response and 1 or 0)
    S.last_disconnect_pending_responses = pending
    local methods = {}
    if ctx.current_response then methods[#methods + 1] = ctx.current_response.method end
    for index = 1, math.min(8, #(ctx.response_queue or {})) do
      methods[#methods + 1] = ctx.response_queue[index].method
    end
    S.last_disconnect_pending_methods = table.concat(methods, ",")
    APP.clients[socket] = nil
    if APP.session and ctx.session_id == S.session_id then reset_session("disconnect") end
  end)
end

local function ntp_now()
  local ms = now_ms()
  local sec = math.floor(ms / 1000)
  local fraction = math.floor((ms % 1000) * 4294967296 / 1000)
  return u32be(sec) .. u32be(fraction)
end

local function on_timing(sock, data, port, ip)
  if type(data) ~= "string" or #data < 32 then return end
  if APP.session then
    APP.session.client_ip = ip
    S.client_ip = ip
  end
  local packet_type = data:byte(2)
  if packet_type == 0xd3 or packet_type == 0x53 then
    S.metrics.timing_responses = S.metrics.timing_responses + 1
    local now = now_ms()
    S.last_timing_response_ms = now
    if APP.session and APP.session.last_timing_request_ms then
      S.last_timing_roundtrip_ms = math.max(0,
        elapsed_ms(now, APP.session.last_timing_request_ms))
    end
    return
  end
  if packet_type ~= 0xd2 and packet_type ~= 0x52 then return end
  local stamp = ntp_now()
  local response = string.char(0x80, 0xd3) .. data:sub(3, 4) .. "\0\0\0\0" ..
                   data:sub(25, 32) .. stamp .. stamp
  pcall(function() sock:send(port, ip, response) end)
end

local function on_control(_, data, _, ip)
  if type(data) ~= "string" or #data < 4 then return end
  if APP.session then
    APP.session.client_ip = ip
    S.client_ip = ip
  end
  local payload_type = (data:byte(2) or 0) & 0x7f
  if payload_type == 0x56 and #data > 4 then
    queue_rtp(data:sub(5), ip)
  elseif payload_type == 0x54 and #data >= 20 then
    S.metrics.sync_packets = S.metrics.sync_packets + 1
    S.last_sync_ms = now_ms()
    local timestamp_less_latency = read_u32(data, 5)
    local timestamp = read_u32(data, 17)
    S.sync_rtp_timestamp = timestamp
    if timestamp and timestamp_less_latency then
      S.sync_latency_frames = (timestamp - timestamp_less_latency) % 4294967296
    end
  end
end

local function poll_timing()
  local session = APP.session
  if APP.native_udp then return end
  if not APP.running or not session or not session.timing_active then return end
  local port = tonumber(session.client_timing_port)
  local ip = session.client_ip or S.client_ip
  if not APP.timing_socket or not port or not ip then return end

  local count = tonumber(session.timing_request_count) or 0
  local interval = count < 3 and APP.config.timing_initial_interval_ms or
                   APP.config.timing_interval_ms
  local now = now_ms()
  if session.last_timing_request_ms and
     elapsed_ms(now, session.last_timing_request_ms) < interval then return end

  -- Classic RAOP timing request: RTCP-like leader/type, fixed sequence 7,
  -- followed by a zero filler and three zero NTP timestamps.
  local request = string.char(0x80, 0xd2) .. u16be(7) .. string.rep("\0", 28)
  local ok = pcall(function() APP.timing_socket:send(port, ip, request) end)
  if ok then
    session.timing_request_count = count + 1
    session.last_timing_request_ms = now
    S.metrics.timing_requests = S.metrics.timing_requests + 1
  end
end

local function create_udp(port, callback)
  local sock = net.createUDPSocket()
  sock:on("receive", callback)
  sock:listen(port, "0.0.0.0")
  return sock
end

local function create_mdns_socket()
  local sock = net.createUDPSocket()
  sock:on("receive", function(_, data)
    if type(data) ~= "string" or #data < 12 then return end
    local flags = read_u16(data, 3) or 0
    if (flags & 0x8000) == 0 and
       (data:find("_raop", 1, true) or data:find("_services", 1, true)) then
      send_mdns(120)
    end
  end)
  local bound, err = pcall(function() sock:listen(5353, "0.0.0.0") end)
  if not bound then
    -- Outbound announcements still work when the firmware's own mDNS daemon
    -- already owns UDP/5353.  Only query-triggered replies are unavailable.
    S.warning = "mDNS receive disabled: " .. tostring(err)
  end
  return sock
end

local function close_network()
  if APP.mdns_socket then send_mdns(0) end
  for socket in pairs(APP.clients) do safe_close(socket) end
  APP.clients = {}
  safe_close(APP.rtsp_server)
  safe_close(APP.mdns_socket)
  safe_close(APP.audio_socket)
  safe_close(APP.control_socket)
  safe_close(APP.timing_socket)
  if APP.native_udp and APP.core and APP.core.network_stop then
    pcall(APP.core.network_stop)
  end
  APP.rtsp_server, APP.mdns_socket, APP.audio_socket = nil, nil, nil
  APP.control_socket, APP.timing_socket = nil, nil
  APP.native_udp = false
  S.native_udp = false
  reset_session("network stopped")
  APP.network_ip = nil
  S.ready = false
end

local function start_network(ip)
  if not net then set_phase("error", "firmware has no net API") return nil end
  APP.network_ip = ip
  local ok, err = pcall(function()
    if APP.config.native_udp_enabled ~= false and
       APP.native_udp_available and APP.core and APP.core.network_start then
      local started, native_err = APP.core.network_start({
        audio_port = APP.config.audio_port,
        control_port = APP.config.control_port,
        timing_port = APP.config.timing_port,
      })
      if started then
        APP.native_udp = true
        S.native_udp = true
      else
        S.warning = "native UDP unavailable; using Lua fallback: " .. tostring(native_err)
      end
    end
    if not APP.native_udp then
      APP.audio_socket = create_udp(APP.config.audio_port, function(_, data, _, source_ip)
        queue_rtp(data, source_ip)
      end)
      APP.control_socket = create_udp(APP.config.control_port, on_control)
      APP.timing_socket = create_udp(APP.config.timing_port, on_timing)
    end
    APP.mdns_socket = create_mdns_socket()
    APP.rtsp_server = net.createServer(net.TCP, APP.config.rtsp_idle_timeout_s)
    APP.rtsp_server:listen(APP.config.rtsp_port, on_connection)
  end)
  if not ok then
    close_network()
    set_phase("error", "network start failed: " .. tostring(err))
    return nil
  end
  S.ready = true
  set_phase("advertising")
  send_mdns(120)
  log("listening", ip, APP.config.rtsp_port)
  return true
end

local function poll_network()
  if not APP.running then return end
  refresh_system_ip(false)
  local ip = current_ip()
  if not ip then
    if APP.network_ip then close_network() end
    if S.phase ~= "waiting_for_wifi" then set_phase("waiting_for_wifi") end
    return
  end
  if ip ~= APP.network_ip then
    if APP.network_ip then close_network() end
    start_network(ip)
  elseif not S.ready then
    start_network(ip)
  end
end

function APP.get_state()
  return snapshot()
end

APP.status = APP.get_state

function APP.subscribe(fn)
  if type(fn) ~= "function" then return nil, "callback must be a function" end
  APP.subscribers[#APP.subscribers + 1] = fn
  pcall(fn, snapshot())
  return fn
end

function APP.unsubscribe(fn)
  for i = #APP.subscribers, 1, -1 do
    if APP.subscribers[i] == fn then table.remove(APP.subscribers, i) end
  end
end

function APP.set_audio_focus_handler(fn)
  if fn ~= nil and type(fn) ~= "function" then return nil, "handler must be a function" end
  APP.audio_focus_handler = fn
  return true
end

function APP.visualizer()
  if APP.core and APP.core.state then
    local ok, value = pcall(APP.core.state)
    if ok and type(value) == "table" then return value end
  end
  return {
    left = S.level_left,
    right = S.level_right,
    playing = S.playing,
    codec = S.codec,
  }
end

function APP.self_test()
  local checks = {}
  local function check(name, condition)
    checks[#checks + 1] = { name = name, ok = condition == true }
  end
  check("u16", read_u16(u16be(0xabcd), 1) == 0xabcd)
  check("u32", read_u32(u32be(0x12345678), 1) == 0x12345678)
  local dns = mdns_packet(120)
  check("mdns_raop", dns:find("_raop", 1, true) ~= nil)
  local tagged = "mlit" .. u32be(12) .. "minm" .. u32be(4) .. "Test"
  check("dmap_title", parse_dmap(tagged).title == "Test")
  local rtp = string.char(0x80, 0x60) .. u16be(7) .. u32be(9) .. u32be(1) .. "\1\2"
  local parsed = parse_rtp(rtp)
  check("rtp", parsed and parsed.seq == 7 and parsed.payload == "\1\2")
  local ok = true
  for _, item in ipairs(checks) do if not item.ok then ok = false end end
  return { ok = ok, checks = checks }
end

function APP.stop(reason)
  if not APP.running then return end
  APP.running = false
  close_network()
  for _, timer in ipairs(APP.timers) do stop_timer(timer) end
  APP.timers = {}
  APP.subscribers = {}
  APP.overlay_dirty = false
  if APP.overlay and APP.overlay.stop then pcall(APP.overlay.stop, APP.overlay) end
  APP.overlay = nil
  if APP.status_route and httpd and httpd.unregister then
    pcall(function() httpd.unregister(httpd.GET, APP.status_route) end)
    APP.status_route = nil
  end
  unregister_webui_routes()
  S.ready = false
  set_phase("stopped", reason)
end

local startup_ok, startup_error = pcall(function()
  local overlay_ok, overlay_module = pcall(dofile, APP.APP_DIR .. "/service_ui.lua")
  if overlay_ok and type(overlay_module) == "table" and type(overlay_module.new) == "function" then
    APP.overlay = overlay_module.new(APP.config)
    APP.overlay_dirty = true
  elseif not overlay_ok then
    log("service overlay unavailable", overlay_module)
  end
  load_native_core()
  register_status_route()
  register_webui_routes()
  add_timer(APP.config.drain_interval_ms, tmr.ALARM_AUTO, drain_audio)
  add_timer(APP.config.overlay_refresh_ms, tmr.ALARM_AUTO, refresh_overlay)
  add_timer(APP.config.timing_poll_ms, tmr.ALARM_AUTO, poll_timing)
  add_timer(APP.config.network_poll_ms, tmr.ALARM_AUTO, poll_network)
  add_timer(APP.config.mdns_interval_ms, tmr.ALARM_AUTO, function() send_mdns(120) end)
  poll_network()
end)
if not startup_ok then
  set_phase("error", "startup failed: " .. tostring(startup_error))
end
