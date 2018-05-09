--[[
  A tool to input numbers (either integers or reals) with.

  Depends on helpers.lua (round_rect)
]]--

local NumberInputter = {}
NumberInputter.__index = NumberInputter

setmetatable(NumberInputter, {
  __call = function (cls, ...) return cls.new(...) end
})

function NumberInputter.new()
  local self = setmetatable({}, NumberInputter)

  self.active = false

  self.max_characters = 15

  self.option_index = 1
  self.options = {} -- {name, hint, value, allow_decimals}

  self.scale = 1


  self._digits = {}

  local digit_string = "0123456789"
  local keys = {".", "BS", "ENTER", "ESC", "TAB"}

  for c in digit_string:gmatch('.') do
    self._digits[c] = true
    table.insert(keys, c)
  end

  self._keys_bound = false
  self._key_binds = {}

  for i,k in pairs(keys) do
    local listener = function() self:_on_key(k) end
    local do_repeat = (k == "BS" or self._digits[k])
    local flags = do_repeat and {repeatable=true} or nil

    table.insert(self._key_binds, {k, "_tst_key_" .. k, listener, flags})
  end

  return self
end

function NumberInputter:cycle_options()
  self.option_index = (self.option_index) % #self.options + 1
  local initial_value = self.options[self.option_index][3]
  if initial_value == 0 then initial_value = nil end
  self.current_value = initial_value and tostring(initial_value) or ""
end

function NumberInputter:enable_key_bindings()
  if not self._keys_bound then
    for k, v in pairs(self._key_binds)  do
      mp.add_forced_key_binding(unpack(v))
    end
    self._keys_bound = true
  end
end

function NumberInputter:disable_key_bindings()
  for k, v in pairs(self._key_binds)  do
    mp.remove_key_binding(v[2]) -- remove by name
  end
  self._keys_bound = false
end

function NumberInputter:start(options, on_enter, on_cancel)
  self.active = true

  self.options = options

  self.option_index = 0
  self:cycle_options() -- Will move index to 1

  self.enter_callback = on_enter
  self.cancel_callback = on_cancel

  self:enable_key_bindings()
end
function NumberInputter:stop()
  self.active = false
  self.current_value = ""

  self:disable_key_bindings()
end

function NumberInputter:_append( part )
  if #self.current_value < self.max_characters then
    self.current_value = self.current_value .. part
  end
end

function NumberInputter:_on_key( key )

  if key == "ESC" then
    local v = tonumber(self.current_value)
    self.current_value = ""

    if self.cancel_callback ~= nil then
      self.cancel_callback(self.options[self.option_index][1], v)
    else
      self:stop()
    end

  elseif key == "ENTER" then
    -- msg.info("NINPUT ENTER")
    local v = tonumber(self.current_value)
    self.current_value = ""

    if self.enter_callback ~= nil then
      self.enter_callback(self.options[self.option_index][1], v)
    else
      self:stop()
    end

  elseif key == "TAB" then
    self:cycle_options()

  elseif key == "BS" then
    self.current_value = self.current_value:sub(1, #self.current_value-1)

  elseif self._digits[key] then
    self:_append(key)

  elseif key == "." then
    local dot_used = self.current_value:find('.', nil, true)
    local not_empty = #self.current_value > 0

    if self.options[self.option_index][4] and not_empty and not dot_used then
      self:_append(".")
    end
  end
end

function NumberInputter:get_ass( w, h )
  local ass = assdraw.ass_new()

  -- Center
  local cx = w / 2
  local cy = h / 2
  local multiple_options = #self.options > 1

  local scaled = function(v) return v * self.scale end

  -- Dialog size
  local b_w = scaled(190)
  local b_h = scaled(multiple_options and 80 or 64)
  local m = scaled(4) -- Margin

  local txt_fmt = "{\\fs%d\\an%d\\bord2}"
  local background_style = string.format("{\\bord0\\1a&H%02X&\\1c&H%02X%02X%02X&}", 128, 0, 0, 0)

  local small_font_size = scaled(14)
  local main_font_size = scaled(18)

  ass:new_event()
  ass:pos(0,0)
  ass:draw_start()
  ass:append(background_style)
  ass:round_rect_cw(cx-b_w/2, cy-b_h/2, cx+b_w/2, cy+b_h/2, scaled(7))
  ass:draw_stop()

  ass:new_event()
  ass:pos(cx-b_w/2 + m, cy+b_h/2 - m)
  ass:append( string.format(txt_fmt, small_font_size, 1) )
  ass:append("[ESC] Cancel")

  ass:new_event()
  ass:pos(cx+b_w/2 - m, cy+b_h/2 - m)
  ass:append( string.format(txt_fmt, small_font_size, 3) )
  ass:append("Accept [ENTER]")

  if multiple_options then
    ass:new_event()
    ass:pos(cx-b_w/2 + m, cy-b_h/2 + m)
    ass:append( string.format(txt_fmt, small_font_size, 7) )
    ass:append("[TAB] Cycle")
  end

  ass:new_event()
  ass:pos(cx, cy-b_h/2 + m + scaled(multiple_options and 15 or 0))
  ass:append( string.format(txt_fmt, main_font_size, 8) )
  ass:append(self.options[self.option_index][2])

  -- Blink the cursor every second
  local cur_style = (math.floor(mp.get_time()) % 2 == 0) and "{\\alpha&HFF}" or ""

  ass:new_event()
  ass:pos(cx, cy + scaled(multiple_options and 7 or 0)
)
  ass:append( string.format(txt_fmt, main_font_size, 5) )
  ass:append(self.current_value .. cur_style .. "|" )

  return ass
end
