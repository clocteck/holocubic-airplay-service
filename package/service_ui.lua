-- Lightweight Now Playing overlay for the AirPlay background service.
-- Lyrics are optional local .lrc files in /sd/airplay_service/lyrics/.
-- Author: sunfang1cn@gmail.com

local M = {}

-- HoloCubic's panel is 320x240.  Keep the overlay away from the acrylic
-- edges and use a subtle, translucent glass capsule over the foreground app.
local X, Y, W, H = 18, 8, 284, 56
local TITLE = 0xE7ECF1
local LYRIC = 0xF7F9FB
local MUTED = 0x8F9AA5
local SHADOW = 0x020407
local TRANSPARENT = rawget(_G, "SERVICE_UI_TRANSPARENT_COLOR") or
  (service_ui and service_ui.TRANSPARENT_COLOR) or 0x00FF00
-- service_ui uses chroma-key transparency rather than a true alpha surface.
-- Partial LVGL opacity blends with the blue transparency key and produces an
-- opaque blue panel.  The final layout therefore uses no panel fill at all;
-- only a one-pixel dark text shadow occupies foreground pixels.

local function clean(value)
  return tostring(value or ""):gsub("[%c]+", " ")
end

local function clip(value, max_chars)
  value = clean(value)
  local pos, count, last = 1, 0, 0
  while pos <= #value and count < max_chars do
    local byte = value:byte(pos)
    local width = byte < 0x80 and 1 or (byte < 0xE0 and 2 or (byte < 0xF0 and 3 or 4))
    if pos + width - 1 > #value then break end
    last, pos, count = pos + width - 1, pos + width, count + 1
  end
  return last < #value and value:sub(1, last) .. "…" or value
end

local function safe_name(value)
  return clean(value):gsub('[\\/:*?"<>|]', "_")
end

local function read_file(path)
  if file and file.getcontents then
    local ok, data = pcall(file.getcontents, path)
    if ok and type(data) == "string" then return data end
  end
  return nil
end

local function load_lrc(directory, title, artist)
  if not title or title == "" then return {} end
  local candidates = {
    directory .. "/" .. safe_name(artist) .. " - " .. safe_name(title) .. ".lrc",
    directory .. "/" .. safe_name(title) .. ".lrc",
  }
  local raw
  for _, path in ipairs(candidates) do
    raw = read_file(path)
    if raw then break end
  end
  if not raw then return {} end

  local lines = {}
  for row in raw:gmatch("[^\r\n]+") do
    local text = row:gsub("^%b[]", "")
    if text ~= "" then
      for minute, second, fraction in row:gmatch("%[(%d+):(%d+)%.?(%d*)%]") do
        local ms = (tonumber(minute) * 60 + tonumber(second)) * 1000
        if fraction ~= "" then ms = ms + math.floor(tonumber(fraction) * (10 ^ (3 - #fraction))) end
        lines[#lines + 1] = { ms = ms, text = clean(text) }
      end
    end
  end
  table.sort(lines, function(a, b) return a.ms < b.ms end)
  return lines
end

function M.new(cfg)
  local self = {
    canvas = nil, lines = {}, lyric_index = 1, lyric_key = nil, stopped = false,
    track_key = nil, track_title = "", remote_title_dynamic = false,
    last_position_ms = 0, last_render_key = nil, playing = false,
    status_title = "", status_artist = "", status_album = "",
    display_header = "", display_content = "",
    native_font = nil, font_attempted = false, font_error = nil,
    x = X,
    y = (cfg.overlay_position == "bottom") and 176 or Y,
    enabled = cfg.overlay_enabled ~= false,
    background = cfg.overlay_background == "gray" and "gray" or "transparent",
    font_size = math.max(14, math.min(18, tonumber(cfg.overlay_font_size) or 16)),
  }
  local directory = cfg.lyrics_dir or ((cfg.APP_DIR or "/sd/apps/airplay_service") .. "/lyrics")
  local font_path = cfg.overlay_font_path or
    ((cfg.APP_DIR or "/sd/apps/airplay_service") .. "/font/airplay_cjk_16.bin")

  local function ensure_font()
    if self.native_font or self.font_attempted then return self.native_font ~= nil end
    self.font_attempted = true
    if type(rawget(_G, "lv_font_load")) ~= "function" then
      self.font_error = "lv_font_load unavailable"
      return false
    end
    local ok, handle = pcall(lv_font_load, font_path)
    if ok and type(handle) == "number" and handle > 0 then
      self.native_font, self.font_error = handle, nil
      return true
    end
    self.font_error = tostring(handle or "font load failed")
    return false
  end

  local function draw_centered_text(y, text, color)
    -- A tiny opaque shadow is more readable over busy foreground apps while
    -- obscuring only glyph pixels instead of a 284x56 rectangle.
    pcall(lv_canvas_draw_text, self.canvas, 15, y + 1, W - 28, text, {
      color = SHADOW, opa = 255, align = LV_TEXT_ALIGN_CENTER,
      font_size = self.font_size, font_handle = self.native_font,
    })
    pcall(lv_canvas_draw_text, self.canvas, 14, y, W - 28, text, {
      color = color, opa = 255, align = LV_TEXT_ALIGN_CENTER,
      font_size = self.font_size, font_handle = self.native_font,
    })
  end

  local function render(header, content, content_color)
    if not self.canvas then return end
    local render_key = header .. "\0" .. content .. "\0" ..
      tostring(content_color)
    if render_key == self.last_render_key then return end
    -- `service_ui.clear()` outside a canvas transaction can leave the old
    -- glyph pixels in the compositor on firmware 1.200.  Begin a complete
    -- keyed frame and explicitly overwrite every pixel before drawing so a
    -- new lyric cannot accumulate over the previous line.
    if lv_canvas_frame_begin then pcall(lv_canvas_frame_begin, self.canvas) end
    pcall(service_ui.clear, self.canvas)
    if lv_canvas_fill_bg then
      pcall(lv_canvas_fill_bg, self.canvas, TRANSPARENT, 255)
    end
    if self.background == "gray" and lv_canvas_draw_rect then
      pcall(lv_canvas_draw_rect, self.canvas, 0, 0, W, H, {
        bg_color = 0x3D4651, bg_opa = 255, radius = 12,
      })
    end
    draw_centered_text(7, header, MUTED)
    draw_centered_text(28, clip(content, 15), content_color)
    if lv_canvas_frame_end then pcall(lv_canvas_frame_end, self.canvas) end
    local visible = false
    if service_ui.is_visible then
      local ok, value = pcall(service_ui.is_visible, self.canvas)
      visible = ok and value == true
    end
    if not visible then pcall(service_ui.show, self.canvas) end
    self.last_render_key = render_key
    self.display_header, self.display_content = header, content
  end

  local function ensure_canvas()
    if self.canvas then return true end
    if not service_ui or not service_ui.acquire then return false end
    local id, err = service_ui.acquire(self.x, self.y, W, H)
    if not id then
      print("[airplay] service_ui.acquire failed", tostring(err or ""))
      return false
    end
    self.canvas = id
    self.last_render_key = nil
    pcall(service_ui.clear, self.canvas)
    ensure_font()
    return true
  end

  local function release_canvas()
    if self.canvas then
      pcall(service_ui.hide, self.canvas)
      pcall(service_ui.release, self.canvas)
      self.canvas = nil
    end
    self.last_render_key = nil
    self.display_header, self.display_content = "", ""
  end

  function self:configure(next)
    next = type(next) == "table" and next or {}
    local enabled = next.overlay_enabled ~= false
    local position = next.overlay_position == "bottom" and "bottom" or "top"
    local x, y = X, position == "bottom" and 176 or Y
    local background = next.overlay_background == "gray" and "gray" or "transparent"
    local font_size = math.max(14, math.min(18, tonumber(next.overlay_font_size) or 16))
    local needs_reacquire = self.x ~= x or self.y ~= y
    self.enabled, self.x, self.y = enabled, x, y
    self.background, self.font_size = background, font_size
    self.last_render_key = nil
    if needs_reacquire or not enabled then release_canvas() end
  end

  function self:update(state)
    if self.stopped or type(state) ~= "table" then return end
    if not self.enabled then
      self.playing = false
      release_canvas()
      return
    end
    if not state.playing then
      self.playing = false
      release_canvas()
      self.lines, self.lyric_index, self.lyric_key = {}, 1, nil
      self.track_key, self.track_title, self.remote_title_dynamic = nil, "", false
      self.last_position_ms = 0
      self.status_title, self.status_artist, self.status_album = "", "", ""
      return
    end
    if not ensure_canvas() then return end

    self.playing = true
    local title, artist, album = clean(state.title), clean(state.artist), clean(state.album)
    local position_ms = math.max(0, tonumber(state.position_ms) or 0)
    self.status_title, self.status_artist, self.status_album = title, artist, album

    -- `title` is deliberately kept live.  Some senders use it for the current
    -- lyric line, while artist/album continue to identify the track.  Only the
    -- stable track title is retained for optional local .lrc lookup.
    local metadata_key = artist .. "\0" .. album
    local position_restarted = position_ms + 5000 < self.last_position_ms
    if self.track_key ~= metadata_key or self.track_title == "" or
       (position_restarted and title ~= "" and title ~= self.track_title) then
      self.track_key = metadata_key
      self.track_title = title
      self.remote_title_dynamic = false
      self.lyric_key = artist .. "\0" .. album .. "\0" .. self.track_title
      self.lyric_index = 1
      self.lines = load_lrc(directory, self.track_title, artist)
    elseif title ~= "" and title ~= self.track_title then
      self.remote_title_dynamic = true
    end
    self.last_position_ms = position_ms

    local lyric = ""
    while self.lyric_index < #self.lines and position_ms >= self.lines[self.lyric_index + 1].ms do
      self.lyric_index = self.lyric_index + 1
    end
    while self.lyric_index > 1 and position_ms < self.lines[self.lyric_index].ms do
      self.lyric_index = self.lyric_index - 1
    end
    if self.lines[self.lyric_index] and position_ms >= self.lines[self.lyric_index].ms then
      lyric = self.lines[self.lyric_index].text
    end

    local header = ""
    if artist ~= "" and album ~= "" then
      header = clip(artist, 7) .. "  ·  " .. clip(album, 4)
    elseif artist ~= "" then
      header = clip(artist, 15)
    elseif album ~= "" then
      header = clip(album, 15)
    end
    if header == "" then header = "AirPlay" end
    local content = title
    local lyric_active = self.remote_title_dynamic
    if not self.remote_title_dynamic and lyric ~= "" then
      content, lyric_active = lyric, true
    end
    if content == "" then content = self.track_title ~= "" and self.track_title or "正在播放" end
    render(header, content, lyric_active and LYRIC or TITLE)
  end

  function self:get_state()
    return {
      active = self.playing and self.canvas ~= nil,
      status_title = self.status_title,
      status_artist = self.status_artist,
      status_album = self.status_album,
      display_header = self.display_header,
      display_content = self.display_content,
      remote_title_dynamic = self.remote_title_dynamic,
      local_lyrics = #self.lines > 0,
      font_loaded = self.native_font ~= nil,
      font_path = font_path,
      font_error = self.font_error,
    }
  end

  function self:stop()
    self.stopped = true
    release_canvas()
    if self.native_font and type(rawget(_G, "lv_font_free")) == "function" then
      pcall(lv_font_free, self.native_font)
    end
    self.native_font = nil
  end

  return self
end

return M
