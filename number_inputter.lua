--[[
  Collection of tools to gather user input.
  NumberInputter can do more than the name says.
  It's a dialog for integer, float, text and even timestamp input.

  ChoicePicker allows one to choose an item from a list.

  Depends on TextMeasurer and helpers.lua (round_rect)
]]--

local NumberInputter = {}
NumberInputter.__index = NumberInputter

setmetatable(NumberInputter, {
  __call = function (cls, ...) return cls.new(...) end
})

NumberInputter.validators = {
  integer = {
    live = function(new_value, old_value)
      if new_value:match("^%d*$") then return new_value
      else return old_value end
    end,
    submit = function(value)
      if value:match("^%d+$") then return tonumber(value)
      elseif value ~= "" then return nil, value end
    end
  },

  signed_integer = {
    live = function(new_value, old_value)
      if new_value:match("^[-]?%d*$") then return new_value
      else return old_value end
    end,
    submit = function(value)
      if value:match("^[-]?%d+$") then return tonumber(value)
      elseif value ~= "" then return nil, value end
    end
  },

  float = {
    live = function(new_value, old_value)
      if new_value:match("^%d*$") or new_value:match("^%d+%.%d*$") then return new_value
      else return old_value end
    end,
    submit = function(value)
      if value:match("^%d+$") or value:match("^%d+%.%d+$") then
        return tonumber(value)
      elseif value:match("^%d%.$") then
        return nil, value:sub(1, -2)
      elseif value ~= "" then
        return nil, value
      end
    end
  },

  signed_float = {
    live = function(new_value, old_value)
      if new_value:match("^[-]?%d*$") or new_value:match("^[-]?%d+%.%d*$") then return new_value
      else return old_value end
    end,
    submit = function(value)
      if value:match("^[-]?%d+$") or value:match("^[-]?%d+%.%d+$") then
        return tonumber(value)
      elseif value:match("^[-]?%d%.$") then
        return nil, value:sub(1, -2)
      elseif value ~= "" then
        return nil, value
      end
    end
  },

  text = {
    live = function(new_value, old_value)
      return new_value:match("^%s*(.*)")
    end,
    submit = function(value)
      if value:match("%s+$") then
        return nil, value:match("^(.-)%s+$")
      elseif value ~= "" then
        return value
      end
    end
  },

  filename = {
    live = function(new_value, old_value)
      return new_value:match("^%s*(.*)"):gsub('[^a-zA-Z0-9 !#$%&\'()+%-,.;=@[%]_ {}]', '')
    end,
    submit = function(value)
      if value:match("%s+$") then
        return nil, value:match("^(.-)%s+$")
      elseif value ~= "" then
        return value
      end
    end
  },

  timestamp = {
    initial_parser = function(v)
      v = math.min(99*3600 + 59*60 + 59.999, math.max(0, v))

      local ms = round_dec((v - math.floor(v)) * 1000)
      if (ms >= 1000) then
        v = v + 1
        ms = ms - 1000
      end

      return ("%02d%02d%02d%03d"):format(
        math.floor(v / 3600),
        math.floor((v % 3600) / 60),
        math.floor(v % 60),
        ms
      )
    end,
    live = function(new_value, old_value)
      if new_value:match("^%d*$") then return new_value, true
      else return old_value, false end
    end,
    submit = function(value)
      local v = tonumber(value:sub(1,2)) * 3600 + tonumber(value:sub(3,4)) * 60 + tonumber(value:sub(5,9)) / 1000
      v = math.min(99*3600 + 59*60 + 59.999, math.max(0, v))

      local ms = round_dec((v - math.floor(v)) * 1000)
      if (ms >= 1000) then
        v = v + 1
        ms = ms - 1000
      end

      local fv = ("%02d%02d%02d%03d"):format(
        math.floor(v / 3600),
        math.floor((v % 3600) / 60),
        math.floor(v % 60),
        ms
      )

      -- Check if formatting matches, if not, return fixed value for resubmit
      if fv == value then return v
      else return nil, fv end
    end
  }
}

function NumberInputter.new()
  local self = setmetatable({}, NumberInputter)

  self.active = false

  self.option_index = 1
  self.options = {} -- {name, hint, value, type_string}

  self.scale = 1

  self.cursor = 1
  self.last_move = 0
  self.replace_mode = false

  self._input_characters = {}

  local input_char_string = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
                            "!\"#$%&'()*+,-./:;<=>?@[\\]^_{|}~#"
  local keys = {
    "ENTER", "ESC", "TAB",
    "BS", "DEL",
    "LEFT", "RIGHT", "HOME", "END",

    -- Extra input characters
    "SPACE", "SHARP",
  }
  local repeatable_keys = Set{"BS", "DEL", "LEFT", "RIGHT"}

  for c in input_char_string:gmatch('.') do
    self._input_characters[c] = c
    table.insert(keys, c)
  end
  self._input_characters["SPACE"] = " "
  self._input_characters["SHARP"] = "#"

  self._keys_bound = false
  self._key_binds = {}

  for i,k in pairs(keys) do
    local listener = function() self:_on_key(k) end
    local do_repeat = (repeatable_keys[k] or self._input_characters[k])
    local flags = do_repeat and {repeatable=true} or nil

    table.insert(self._key_binds, {k, "_input_" .. i, listener, flags})
  end

  return self
end

function NumberInputter:escape_ass(text)
  return text:gsub('\\', '\\\226\129\160'):gsub('{', '\\{')
end

function NumberInputter:cycle_options()
  self.option_index = (self.option_index) % #self.options + 1

  local initial_value = self.options[self.option_index][3]
  local parser = self.validators[self.options[self.option_index][4]].initial_parser or tostring

  if type(initial_value) == "function" then initial_value = initial_value() end
  self.current_value = initial_value and parser(initial_value) or ""
  self.cursor = 1

  self.replace_mode = (self.options[self.option_index][4] == "timestamp")
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
  self.was_paused = mp.get_property_native('pause')
  if not self.was_paused then
    mp.set_property_native('pause', true)
    mp.osd_message("Paused playback for input")
  end

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
  if not self.was_paused then
    mp.set_property_native('pause', false)
    mp.osd_message("Resumed playback")
  end

  self:disable_key_bindings()
end

function NumberInputter:_append( part )
  local l = self.current_value:len()
  local validator_data = self.validators[self.options[self.option_index][4]]

  if self.replace_mode then
    if self.cursor > 1 then

      local new_value = self.current_value:sub(1, l - self.cursor + 1) .. part .. self.current_value:sub(l - self.cursor + 3)
      self.current_value, changed = validator_data.live(new_value, self.current_value, self)
      if changed then
        self.cursor = math.max(1, self.cursor - 1)
      end
    end

  else
    local new_value = self.current_value:sub(1, l - self.cursor + 1) .. part .. self.current_value:sub(l - self.cursor + 2)

    self.current_value = validator_data.live(new_value, self.current_value, self)
  end
end

function NumberInputter:_on_key( key )

  if key == "ESC" then
    self:stop()
    if self.cancel_callback then
      self.cancel_callback()
    end

  elseif key == "ENTER" then
    local opt = self.options[self.option_index]
    local extra_validation = opt[5]

    local value, repl = self.validators[opt[4]].submit(self.current_value)
    if value and extra_validation then
      local number_formats = Set{"integer", "float", "signed_float", "signed_integer", "timestamp"}
      if number_formats[opt[4]] then
        if extra_validation.min and value < extra_validation.min then repl = tostring(extra_validation.min) end
        if extra_validation.max and value > extra_validation.max then repl = tostring(extra_validation.max) end
      end
    end

    if repl then
      self.current_value = repl
    else

      self:stop()
      if self.enter_callback then
        self.enter_callback(opt[1], value)
      end
    end

  elseif key == "TAB" then
    self:cycle_options()

  elseif key == "BS" then
    -- Remove character to the left
    local l = self.current_value:len()
    local c = self.cursor

    if not self.replace_mode and c <= l then
      self.current_value = self.current_value:sub(1, l - c) .. self.current_value:sub(l - c + 2)
      self.cursor = math.min(c, self.current_value:len() + 1)

    elseif self.replace_mode then
      if c <= l then
        self.current_value = self.current_value:sub(1, l - c) .. '0' .. self.current_value:sub(l - c + 2)
        self.cursor = math.min(l + 1, c + 1)
      end
    end

  elseif key == "DEL" then
    -- Remove character to the right
    local l = self.current_value:len()
    local c = self.cursor

    if not self.replace_mode and c > 1 then
      self.current_value = self.current_value:sub(1, l - c + 1) .. self.current_value:sub(l - c + 3)
      self.cursor = math.min(math.max(1, c - 1), self.current_value:len() + 1)

    elseif self.replace_mode then
      if c > 1 then
        self.current_value = self.current_value:sub(1, l - c + 1) .. '0' .. self.current_value:sub(l - c + 3)
        self.cursor = math.max(1, c - 1)
      end
    end

  elseif key == "LEFT" then
    self.cursor = math.min(self.cursor + 1, self.current_value:len() + 1)
  elseif key == "RIGHT" then
    self.cursor = math.max(self.cursor - 1, 1)
  elseif key == "HOME" then
    self.cursor = self.current_value:len() + 1
  elseif key == "END" then
    self.cursor = 1

  elseif self._input_characters[key] then
    self:_append(self._input_characters[key])

  end

  self.last_move = mp.get_time()
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
  local bgc = 16
  local background_style = string.format("{\\bord0\\1a&H%02X&\\1c&H%02X%02X%02X&}", 96, bgc, bgc, bgc)

  local small_font_size = scaled(14)
  local main_font_size = scaled(18)

  local value_width = TextMeasurer:calculate_width(self.current_value, main_font_size)
  local cursor_width = TextMeasurer:calculate_width("|", main_font_size)

  b_w = math.max(b_w, value_width + scaled(20))

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

  local value = self.current_value
  local cursor = self.cursor
  if self.options[self.option_index][4] == "timestamp" then
    value = value:sub(1, 2) .. ":" .. value:sub(3, 4) .. ":" .. value:sub(5, 6) .. "." .. value:sub(7, 9)
    cursor = cursor + (cursor > 4 and 1 or 0) + (cursor > 6 and 1 or 0) + (cursor > 8 and 1 or 0)
  end

  local safe_text = self:escape_ass(value)

  local text_x, text_y = (cx - value_width/2), (cy + scaled(multiple_options and 7 or 0))
  ass:new_event()
  ass:pos(text_x, text_y)
  ass:append( string.format(txt_fmt, main_font_size, 4) )
  ass:append(safe_text)

  -- Blink the cursor
  local cur_style = (math.floor( (mp.get_time() - self.last_move) * 1.5 ) % 2 == 0) and "{\\alpha&H00&}" or "{\\alpha&HFF&}"

  ass:new_event()
  ass:pos(text_x - (cursor > 1 and cursor_width or 0)/2, text_y)
  ass:append( string.format(txt_fmt, main_font_size, 4) )
  ass:append("{\\alpha&HFF&}" .. self:escape_ass(value:sub(1, value:len() - cursor + 1)) .. cur_style .. "{\\bord1}|" )

  return ass
end

-- -- -- --

local ChoicePicker = {}
ChoicePicker.__index = ChoicePicker

setmetatable(ChoicePicker, {
  __call = function (cls, ...) return cls.new(...) end
})

function ChoicePicker.new()
  local self = setmetatable({}, ChoicePicker)

  self.active = false

  self.choice_index = 1
  self.choices = {} -- { { name = "Visible name", value = "some_value" }, ... }

  self.scale = 1

  local keys = {
    "UP", "DOWN", "PGUP", "PGDWN",
    "ENTER", "ESC"
  }
  local repeatable_keys = Set{"UP", "DOWN"}

  self._keys_bound = false
  self._key_binds = {}

  for i,k in pairs(keys) do
    local listener = function() self:_on_key(k) end
    local do_repeat = repeatable_keys[k]
    local flags = do_repeat and {repeatable=true} or nil

    table.insert(self._key_binds, {k, "_picker_key_" .. k, listener, flags})
  end

  return self
end

function ChoicePicker:shift_selection(offset, no_wrap)
  local n = #self.choices

  if n == 0 then
    return 0
  end

  local target_index = self.choice_index - 1 + offset
  if no_wrap then
    target_index = math.max(0, math.min(n - 1, target_index))
  end

  self.choice_index = (target_index % n) + 1
end


function ChoicePicker:enable_key_bindings()
  if not self._keys_bound then
    for k, v in pairs(self._key_binds)  do
      mp.add_forced_key_binding(unpack(v))
    end
    self._keys_bound = true
  end
end

function ChoicePicker:disable_key_bindings()
  for k, v in pairs(self._key_binds)  do
    mp.remove_key_binding(v[2]) -- remove by name
  end
  self._keys_bound = false
end

function ChoicePicker:start(choices, on_enter, on_cancel)
  self.active = true

  self.choices = choices

  self.choice_index = 1
  -- self:cycle_options() -- Will move index to 1

  self.enter_callback = on_enter
  self.cancel_callback = on_cancel

  self:enable_key_bindings()
end
function ChoicePicker:stop()
  self.active = false

  self:disable_key_bindings()
end

function ChoicePicker:_on_key( key )

  if key == "UP" then
    self:shift_selection(-1)

  elseif key == "DOWN" then
    self:shift_selection(1)

  elseif key == "PGUP" then
    self.choice_index = 1

  elseif key == "PGDWN" then
    self.choice_index = #self.choices

  elseif key == "ESC" then
    self:stop()
    if self.cancel_callback then
      self.cancel_callback()
    end

  elseif key == "ENTER" then
    self:stop()
    if self.enter_callback then
      self.enter_callback(self.choices[self.choice_index].value)
    end

  end
end

function ChoicePicker:get_ass( w, h )
  local ass = assdraw.ass_new()

  -- Center
  local cx = w / 2
  local cy = h / 2
  local choice_count = #self.choices

  local s = function(v) return v * self.scale end

  -- Dialog size
  local b_w = s(220)
  local b_h = s(20 + 20 + (choice_count * 20) + 10)
  local m = s(5) -- Margin

  local small_font_size = s(14)
  local main_font_size = s(18)

  for j, choice in pairs(self.choices) do
    local name_width = TextMeasurer:calculate_width(choice.name, main_font_size)
    b_w = math.max(b_w, name_width + s(20))
  end

  local e_l = cx - b_w/2
  local e_r = cx + b_w/2
  local e_t = cy - b_h/2
  local e_b = cy + b_h/2

  local txt_fmt = "{\\fs%d\\an%d\\bord2}"
  local bgc = 16
  local background_style = string.format("{\\bord0\\1a&H%02X&\\1c&H%02X%02X%02X&}", 96, bgc, bgc, bgc)

  local line_h = s(20)
  local line_h2 = s(22)
  local corner_radius = s(7)

  ass:new_event()
  ass:pos(0,0)
  ass:draw_start()
  ass:append(background_style)
  -- Main BG
  ass:round_rect_cw(e_l, e_t, e_r, e_b, corner_radius)
  -- Options title
  round_rect(ass, e_l + line_h*2, e_t-line_h2, e_r - line_h*2, e_t,  corner_radius, corner_radius, 0, 0)
  ass:draw_stop()

  ass:new_event()
  ass:pos(cx, e_t - line_h2/2)
  ass:append( string.format(txt_fmt, main_font_size, 5) )
  ass:append("Choose")

  ass:new_event()
  ass:pos(e_r - m, e_b - m)
  ass:append( string.format(txt_fmt, small_font_size, 3) )
  ass:append("Choose [ENTER]")

  ass:new_event()
  ass:pos(e_l + m, e_b - m)
  ass:append( string.format(txt_fmt, small_font_size, 1) )
  ass:append("[ESC] Cancel")

  ass:new_event()
  ass:pos(e_l + m, e_t + m)
  ass:append( string.format(txt_fmt, small_font_size, 7) )
  ass:append("[UP]/[DOWN] Select")

  local color_text = function( text, r, g, b )
    return string.format("{\\c&H%02X%02X%02X&}%s{\\c}", b, g, r, text)
  end

  local color_gray = {190, 190, 190}

  local item_height = line_h;
  local text_height = main_font_size;
  local item_margin = (item_height - text_height) / 2;

  local base_y = e_t + m + item_height

  local choice_index = 0

  for j, choice in pairs(self.choices) do
    choice_index = choice_index + 1

    if choice_index == self.choice_index then
      ass:new_event()
      ass:pos(0,0)
      ass:append( string.format("{\\bord0\\1a&H%02X&\\1c&H%02X%02X%02X&}", 128, 250, 250, 250) )
      ass:draw_start()
      ass:rect_cw(e_l, base_y - item_margin, e_r, base_y + item_height + item_margin)
      ass:draw_stop()
    end

    ass:new_event()
    ass:pos(cx, base_y)
    ass:append(string.format(txt_fmt, text_height, 8))
    ass:append(choice.name)

    base_y = base_y + line_h
  end

  return ass
end
