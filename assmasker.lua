local ASSMasker = {}
ASSMasker.__index = ASSMasker

setmetatable(ASSMasker, {
  __call = function (cls, ...) return cls.new(...) end
})

function ASSMasker.new(display_state)
  local self = setmetatable({}, ASSMasker)
  local script_name = mp.get_script_name()
  self.keybind_group = script_name .. "_ASSMasker_binds"

  self.display_state = display_state

  self.tick_callback = nil
  self.tick_timer = mp.add_periodic_timer(1/30, function()
    if self.tick_callback then self.tick_callback() end
  end)
  self.tick_timer:stop()

  self.text_size = 18

  self.overlay_transparency = 160
  self.overlay_lightness = 0

  self.handle_size   = 5 -- radius
  self.line_distance = 5
  self.snap_distance = 10

  self.high_visibility = false
  self.inverted = false
  self.mask_shapes = {}
  self.active_shape = nil
  --[[
    local shape = {
      points = { {x=0,y=0}, ...},
      inverted = false
    }
  ]]--

  self.active = false
  self.snap_move     = false
  self.straight_move = false

  self.mouse_screen = {x=0, y=0}
  self.mouse_video  = {x=0, y=0}

  self.dragging = nil
  -- self.drag_offset = {x=0, y=0}
  self.drag_start = {x=0, y=0}

  self._key_binds = {
    {"mouse_move", function()  self:update_mouse_position()   end },
    {"mouse_btn0", function(e) self:on_mouse("mouse_btn0", e) end, {complex=true}},
    {"mouse_btn2", function(e) self:on_mouse("mouse_btn2", e) end, {complex=true}},
    {"ctrl+mouse_btn0", function(e) self:on_mouse("mouse_btn0", e, true) end, {complex=true}},
    {"shift+mouse_btn0", function(e) self:on_mouse("mouse_btn0", e, false, true) end, {complex=true}},
    {"ctrl+shift+mouse_btn0", function(e) self:on_mouse("mouse_btn0", e, true, true) end, {complex=true}},
    -- Catch double clicks
    {"mbtn_left_dbl",    function() end},

    {"c", function() self:key_event("CLEAR")  end },
    {"i", function() self:key_event("INVERT") end },
    {"g", function() self:key_event("GRAB")   end },
    {"ctrl+g", function() self:key_event("GRAB_STRAIGHT")   end },
    {"shift+i", function() self:key_event("INVERT_CANVAS") end },
    {"z", function() self:key_event("CONTRAST")   end },

    {"b", function() self:key_event("BLUR_ADD")    end, {repeatable=true} },
    {"B", function() self:key_event("BLUR_REMOVE") end, {repeatable=true} },

    {"pgup",  function() self:key_event("MOVE_UP")   end },
    {"pgdwn", function() self:key_event("MOVE_DOWN") end },

    {"home", function() self:key_event("CHOOSE_NEXT")     end },
    {"end",  function() self:key_event("CHOOSE_PREVIOUS") end },

    {"del", function() self:key_event("DELETE_SHAPE") end, {repeatable=true} },
    {"x",   function() self:key_event("DELETE_POINT") end, {repeatable=true} },
    {"ENTER", function() self:key_event("ENTER") end },
    {"ESC",   function() self:key_event("ESC")   end }
  }

  self._keys_bound = false

  for k, v in pairs(self._key_binds) do
    -- Insert a key name into the tables
    table.insert(v, 2, self.keybind_group .. "_key_" .. v[1])
  end

  return self
end


function ASSMasker:enable_key_bindings()
  if not self._keys_bound then
    for k, v in pairs(self._key_binds)  do
      mp.add_forced_key_binding(unpack(v))
    end
    -- Clear "allow-vo-dragging"
    mp.input_enable_section("input_forced_" .. mp.script_name)
    self._keys_bound = true
  end
end


function ASSMasker:disable_key_bindings()
  for k, v in pairs(self._key_binds)  do
    mp.remove_key_binding(v[2]) -- remove by name
  end
  self._keys_bound = false
end

function ASSMasker:collect_mask_data()
  local mask_data = {
    inverted = self.inverted,
    shapes = {},

    min_x = nil,
    min_y = nil,
    max_x = nil,
    max_y = nil,

    min_x_blur = nil,
    min_y_blur = nil,
    max_x_blur = nil,
    max_y_blur = nil,

    render_to_file = function(mask_self, w, h, file_path)
      return self:render_mask_data(mask_self, w, h, file_path)
    end
  }

  local min_nil = function(a, b) return math.min(a or b, b) end
  local max_nil = function(a, b) return math.max(a or b, b) end

  for i, shape in ipairs(self.mask_shapes) do
    shape_data = {
      inverted = shape.inverted,
      blur = shape.blur,

      points = {},

      min_x = nil,
      min_y = nil,
      max_x = nil,
      max_y = nil,

      min_x_blur = nil,
      min_y_blur = nil,
      max_x_blur = nil,
      max_y_blur = nil
    }

    for j, p in ipairs(shape.points) do
      shape_data.points[#shape_data.points+1] = {x=p.x, y=p.y}

      shape_data.min_x = min_nil(shape_data.min_x, p.x)
      shape_data.min_y = min_nil(shape_data.min_y, p.y)
      shape_data.max_x = max_nil(shape_data.max_x, p.x)
      shape_data.max_y = max_nil(shape_data.max_y, p.y)
    end

    -- Manually tested
    local blur_radius = shape.blur * 1.5
    shape_data.min_x_blur = shape_data.min_x - blur_radius
    shape_data.min_y_blur = shape_data.min_y - blur_radius
    shape_data.max_x_blur = shape_data.max_x + blur_radius
    shape_data.max_y_blur = shape_data.max_y + blur_radius

    mask_data.shapes[#mask_data.shapes+1] = shape_data

    -- Update bounds if shape differs from canvas
    -- (canvas-invert: white, shape-invert: black)
    if shape_data.inverted == mask_data.inverted then
      mask_data.min_x = min_nil(mask_data.min_x, shape_data.min_x)
      mask_data.min_y = min_nil(mask_data.min_y, shape_data.min_y)
      mask_data.max_x = max_nil(mask_data.max_x, shape_data.max_x)
      mask_data.max_y = max_nil(mask_data.max_y, shape_data.max_y)

      mask_data.min_x_blur = min_nil(mask_data.min_x_blur, shape_data.min_x_blur)
      mask_data.min_y_blur = min_nil(mask_data.min_y_blur, shape_data.min_y_blur)
      mask_data.max_x_blur = max_nil(mask_data.max_x_blur, shape_data.max_x_blur)
      mask_data.max_y_blur = max_nil(mask_data.max_y_blur, shape_data.max_y_blur)
    end
  end

  if #mask_data.shapes > 0 then
    return mask_data
  else
    return nil
  end
end

function ASSMasker:key_event(name)
  if name == "ENTER" then
    local mask_data = self:collect_mask_data()

    self:stop_masking()

    if self.callback_on_crop then
      self.callback_on_crop(mask_data)
    else
      mp.set_osd_ass(0,0, '')
    end

  elseif name == "ESC" then
    self:stop_masking()

    if self.callback_on_cancel then
      self.callback_on_cancel()
    else
      mp.set_osd_ass(0,0, '')
    end

  elseif name == "DELETE_SHAPE" then
    if self.active_shape then
      self:delete_shape(self.active_shape)
    end

  elseif name == "DELETE_POINT" then
    if self.active_shape then
      -- Remove last point
      self.active_shape.points[#self.active_shape.points] = nil

      -- If no points, remove shape
      if #self.active_shape.points == 0 then
        self:delete_shape(self.active_shape)
      end
    end

  elseif name == "MOVE_UP" then
    if self.active_shape then
      local total_shapes = #self.mask_shapes

      for i, shape in ipairs(self.mask_shapes) do
        if shape == self.active_shape and i ~= total_shapes then
          table.remove(self.mask_shapes, i)
          table.insert(self.mask_shapes, i+1, shape)
          break
        end
      end
    end

  elseif name == "MOVE_DOWN" then
    if self.active_shape then
      local total_shapes = #self.mask_shapes

      for i, shape in ipairs(self.mask_shapes) do
        if shape == self.active_shape and i ~= 1 then
          table.remove(self.mask_shapes, i)
          table.insert(self.mask_shapes, i-1, shape)
          break
        end
      end
    end

  elseif name == "CHOOSE_PREVIOUS" then
    if #self.mask_shapes > 0 then
      local active_index = 1
      for i, shape in ipairs(self.mask_shapes) do
        if shape == self.active_shape then
          active_index = i
          break
        end
      end
      self.dragging = nil
      self.active_shape = self.mask_shapes[math.max(1, active_index-1)]
    end

  elseif name == "CHOOSE_NEXT" then
    if #self.mask_shapes > 0 then
      local active_index = #self.mask_shapes
      for i, shape in ipairs(self.mask_shapes) do
        if shape == self.active_shape then
          active_index = i
          break
        end
      end
      self.dragging = nil
      self.active_shape = self.mask_shapes[math.min(#self.mask_shapes, active_index+1)]
    end

  elseif name == "INVERT" then
    if self.active_shape then
      self.active_shape.inverted = not self.active_shape.inverted
    end

  elseif name == "GRAB" or name == "GRAB_STRAIGHT" then
    if self.active_shape then
      self:update_mouse_position()
      if self.dragging then
        self.dragging = nil
      else
        self.dragging = self.active_shape.points
        self.straight_move = name == "GRAB_STRAIGHT"
        self:_start_drag({x=self.mouse_video.x, y=self.mouse_video.y})
      end
    end

  elseif name == "BLUR_ADD" then
    if self.active_shape then
      self.active_shape.blur = self.active_shape.blur + 1
    end

  elseif name == "BLUR_REMOVE" then
    if self.active_shape then
      self.active_shape.blur = math.max(0, self.active_shape.blur - 1)
    end

  elseif name == "CLEAR" then
    self.active_shape = nil
    self.dragging = nil

  elseif name == "INVERT_CANVAS" then
    self.inverted = not self.inverted

  elseif name == "CONTRAST" then
    self.high_visibility = not self.high_visibility

  end
end

function ASSMasker:delete_shape(shape)
  for i, v in ipairs(self.mask_shapes) do
    if v == shape then
      table.remove(self.mask_shapes, i)
      break
    end
  end

  if shape == self.active_shape then
    self.active_shape = nil
    self.dragging = nil
  end
end

function ASSMasker:start_masking(on_crop, on_cancel, old_mask_data)
  -- Refresh display state
  self.display_state:recalculate_bounds(true)
  if self.display_state.video_ready then
    self.active = true
    self.tick_timer:resume()

    self.mask_shapes = {}
    self.active_shape = nil
    self.dragging = nil

    if old_mask_data then
      self.inverted = old_mask_data.inverted

      for i, shape_data in ipairs(old_mask_data.shapes) do
        local shape = {
          inverted = shape_data.inverted,
          blur = shape_data.blur,
          points = {}
        }
        self.mask_shapes[#self.mask_shapes+1] = shape
        for j, p in ipairs(shape_data.points) do
          shape.points[#shape.points+1] = {x=p.x, y=p.y}
        end
      end
    end

    self.callback_on_crop = on_crop
    self.callback_on_cancel = on_cancel

    self:enable_key_bindings()
    self:update_mouse_position()

  end
end

function ASSMasker:stop_masking(clear)
  self.active = false
  self.tick_timer:stop()

  self:disable_key_bindings()
end


function ASSMasker:update_mouse_position()
  -- These are real on-screen coords.
  self.mouse_screen.x, self.mouse_screen.y = mp.get_mouse_pos()

  if self.display_state:recalculate_bounds() and self.display_state.video_ready then
    -- These are on-video coords.
    local mx, my = self.display_state:screen_to_video(self.mouse_screen.x, self.mouse_screen.y)
    self.mouse_video.x = mx
    self.mouse_video.y = my
  end

  if self.dragging then
    local snap_move = self.snap_move and #self.dragging == 1

    local offset_x = self.mouse_video.x - self.drag_start.x
    local offset_y = self.mouse_video.y - self.drag_start.y

    if self.straight_move then
      if math.abs(offset_x) > math.abs(offset_y) then
        offset_y = 0
      else
        offset_x = 0
      end
    end

    for i, p in ipairs(self.dragging) do
      p.x = self.drag_offsets[p].x + offset_x
      p.y = self.drag_offsets[p].y + offset_y
    end

    if snap_move then
      local p = self.dragging[1]
      local snap_x, snap_y = self:find_line_snap(p)

      p.x = snap_x or p.x
      p.y = snap_y or p.y
    end
  end

end

function ASSMasker:find_handle(shape, pos)
  -- Find a handle under the given position
  local max_distance = self.display_state.scale.x * (self.handle_size * self.handle_size)

  for i=#shape.points,1,-1 do
    local p = shape.points[i]
    local dx, dy = pos.x - p.x, pos.y - p.y
    local distance = dx*dx + dy*dy

    if distance <= max_distance then
      return i, p
    end
  end
end


function ASSMasker:find_shape(p)
  -- Find a shape under the given position

  for i=#self.mask_shapes, 1, -1 do
    local shape = self.mask_shapes[i]

    local points, total_points = shape.points, #shape.points
    local inside = false
    local i, j = 1, total_points

    while i <= total_points do
      if ( (points[i].y > p.y) ~= (points[j].y > p.y) ) and ( p.x < (points[j].x - points[i].x) * (p.y - points[i].y) / (points[j].y - points[i].y) + points[i].x ) then
        inside = not inside
      end
      j = i
      i = i + 1
    end

    if inside then
      return shape, i
    end
  end

end

function ASSMasker:find_line(shape, pos)
  -- Find the closest line under the given position

  local max_distance = self.display_state.scale.x * self.line_distance * self.line_distance

  local sqr = function(v) return v * v end
  local dist2 = function(a, b) return sqr(a.x - b.x) + sqr(a.y - b.y) end
  local dist2seg = function(a, b, p)
    local l2 = dist2(a, b)

    if l2 == 0 then
      return dist2(a, p)
    else
      local t = math.max(0, math.min(1, ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / l2))
      return dist2( p, { x = (a.x + t * (b.x - a.x)),
                         y = (a.y + t * (b.y - a.y)) })
    end
  end

  local closest = nil
  local min_dist = nil

  local points = shape.points
  for i = 1, #points do
    local dist_sqr = dist2seg(points[i], points[(i % #points) + 1], pos)

    if not min_dist or dist_sqr < min_dist then
      min_dist = dist_sqr
      closest = i
    end
  end

  if closest then
    local a = points[closest]
    local b = points[(closest % #points) + 1]

    if min_dist <= max_distance then
      return {a, b}, closest, min_dist
    end
  end

end

function ASSMasker:find_line_snap(pos)
  local max_distance = self.display_state.scale.x * self.snap_distance

  local c_x = nil
  local min_dx = nil

  local c_y = nil
  local min_dy = nil

  local dragging_points = {}
  if self.dragging then
    for i, p in ipairs(self.dragging) do
      dragging_points[p] = true
    end
  end

  for i, shape in ipairs(self.mask_shapes) do
    for j, p in ipairs(shape.points) do
      if not dragging_points[p] then
        local dx = math.abs(pos.x - p.x)
        local dy = math.abs(pos.y - p.y)

        if (not min_dx or dx < min_dx) and dx <= max_distance then
          min_dx = dx
          c_x = p.x
        end

        if (not min_dy or dy < min_dy) and dy <= max_distance then
          min_dy = dy
          c_y = p.y
        end
      end
    end
  end

  return c_x, c_y
end

function ASSMasker:_start_drag(pos)
  self.drag_start = pos
  self.drag_offsets = {}

  for i, p in ipairs(self.dragging) do
    self.drag_offsets[p] = {x=p.x, y=p.y}
  end
end

function ASSMasker:on_mouse(button, event, ctrl_down, shift_down)
  mouse_down = event.event == "down"
  local mouse_pos = {x=self.mouse_video.x, y=self.mouse_video.y}

  if button == "mouse_btn0" and mouse_down then
    if not self.dragging then
      if self.active_shape then
        local pi, p = self:find_handle(self.active_shape, mouse_pos)

        if pi then
          -- Drag found point
          self.dragging = {p}
        else
          local line_points, line_index = self:find_line(self.active_shape, mouse_pos)
          if line_points and shift_down then
            self.dragging = {{x=mouse_pos.x, y=mouse_pos.y}}
            -- Insert a new point
            table.insert(self.active_shape.points, line_index+1, self.dragging[1])
            -- Disable snap
            shift_down = false
          elseif line_points then
            -- Drag found line points
            self.dragging = line_points
          else
            -- Create a new point, add it to shape and drag it
            self.dragging = {{x=mouse_pos.x, y=mouse_pos.y}}
            self.active_shape.points[#self.active_shape.points+1] = self.dragging[1]
          end
        end

      else -- No active shape, check if clicking on a shape or create new

        local pi, p, shape = nil, nil
        for i, mask_shape in ipairs(self.mask_shapes) do
          pi, p = self:find_handle(mask_shape, mouse_pos)
          if pi then
            shape = mask_shape
            break
          end
        end

        if pi then
          self.dragging = {p}
          self.active_shape = shape
        else
          -- Check if clicking over shape (not just handle)
          shape = self:find_shape(mouse_pos)
          if shape then
            self.active_shape = shape
          else
            -- Create new shape and drag the point
            self.dragging = {{x=mouse_pos.x, y=mouse_pos.y}}
            self.active_shape = { points=self.dragging, inverted=false, blur=0 }
            self.mask_shapes[#self.mask_shapes+1] = self.active_shape
          end
        end

      end

      self.snap_move     = shift_down
      self.straight_move = ctrl_down

      if self.dragging then
        self:_start_drag(mouse_pos)
      end
    end

  elseif button == "mouse_btn2" and mouse_down then

    if not self.dragging and self.active_shape then
      local pi, p = self:find_handle(self.active_shape, mouse_pos)

      if pi then
        -- Remove point
        table.remove(self.active_shape.points, pi)
        -- If no points, remove shape
        if #self.active_shape.points == 0 then
          self:delete_shape(self.active_shape)
        end
      end
    end

  elseif not mouse_down then
    -- Clear drag on mouse release
    self.dragging = nil
    self.snap_move = false
    self.straight_move = false
  end
end


function ASSMasker:get_render_ass()

  self:update_mouse_position()

  local ass = assdraw.ass_new()

  local rgb2hex = function(r, g, b) return ('%02X%02X%02X'):format(b, g, r) end

  local colors = {}
  colors.fill        = rgb2hex(255,255,255)
  colors.fill_invert = rgb2hex(0, 0, 0)
  colors.fill_trans  = 196 + 32
  colors.fill_invert_trans = 196 - 32

  colors.line        = rgb2hex(128, 128, 128)
  colors.line_active = rgb2hex(255, 255, 255)
  colors.line_trans  = 128

  colors.handle_fill = colors.fill
  colors.handle_fill_trans = 128
  colors.handle_line = colors.line
  colors.handle_line_trans = 128

  if self.high_visibility then
    colors.line        = rgb2hex(196, 0, 0)
    colors.line_active = rgb2hex(255, 0, 0)
    colors.handle_line = colors.line_active

    colors.line_trans         = 0
    colors.handle_fill_trans  = 255
    colors.handle_line_trans  = 0
  end

  local styles = {
    mask          = ("{\\bord0\\1a&H%02X&\\1c&H%s&}"):format(colors.fill_trans, colors.fill),
    mask_inverted = ("{\\bord0\\1a&H%02X&\\1c&H%s&}"):format(colors.fill_invert_trans, colors.fill_invert),

    line        = ("{\\bord1\\1a&HFF&\\3a&H%02X&\\3c&H%s&}"):format(colors.line_trans, colors.line),
    line_active = ("{\\bord1\\1a&HFF&\\3a&H%02X&\\3c&H%s&}"):format(colors.line_trans, colors.line_active),

    handle = ("{\\bord1\\1a&H%02X&\\3a&H%02X&\\1c&H%s&\\3c&H%s&}"):format(colors.handle_fill_trans, colors.handle_line_trans, colors.handle_fill, colors.handle_line)
  }

  for i, shape in ipairs(self.mask_shapes) do

    -- Draw fill
    ass:new_event()
    ass:pos(0, 0)
    ass:append(shape.inverted and styles.mask_inverted or styles.mask)

    if shape.blur > 0 then
      ass:append(('{\\blur%f}'):format(shape.blur / self.display_state.scale.x))
    end
    ass:draw_start()

    local total_points = #shape.points

    for i, point in ipairs(shape.points) do
      local screen_x, screen_y = self.display_state:video_to_screen(point.x, point.y)
      if i == 1 then
        ass:move_to(screen_x, screen_y)
      else
        ass:line_to(screen_x, screen_y)
      end
    end

    ass:draw_stop()

    -- Draw lines
    ass:new_event()
    ass:pos(0, 0)
    if shape == self.active_shape then
      ass:append(styles.line_active)
    else
      ass:append(styles.line)
    end
    ass:draw_start()

    for i, point in ipairs(shape.points) do
      local screen_x, screen_y = self.display_state:video_to_screen(point.x, point.y)
      if i == 1 then
        ass:move_to(screen_x, screen_y)
      else
        ass:line_to(screen_x, screen_y)
        ass:move_to(screen_x, screen_y)
      end
    end
    if #shape.points > 2 then
      local screen_x, screen_y = self.display_state:video_to_screen(shape.points[1].x, shape.points[1].y)
      ass:line_to(screen_x, screen_y)
    end

    ass:draw_stop()

    -- Draw handles
    ass:new_event()
    ass:pos(0, 0)
    ass:append(styles.handle)
    ass:draw_start()

    for i, point in ipairs(shape.points) do
      if i == total_points then
        ass:draw_stop()
        ass:new_event()
        ass:pos(0, 0)
        ass:append(styles.handle)
        ass:append(("{\\1a&H%02X&\\1c&H%02X%02X%02X&}"):format(
          256,
          255, 255, 255
        ))
        ass:draw_start()
      end
      local screen_x, screen_y = self.display_state:video_to_screen(point.x, point.y)
      ass:round_rect_cw(screen_x - self.handle_size, screen_y - self.handle_size,
        screen_x + self.handle_size, screen_y + self.handle_size,
        self.handle_size
      )
    end

    ass:draw_stop()
  end

  if true then
    ass:new_event()
    ass:pos(self.display_state.screen.width - 5, 5)
    ass:append( string.format("{\\fs%d\\an%d\\bord2}", self.text_size, 9) )

    local fmt_key = function( key, text ) return string.format("[{\\c&HBEBEBE&}%s{\\c} %s]", key:upper(), text) end

    canvas_state = ('Invert canvas (%s)'):format(self.inverted and 'white' or 'black')

    lines = {
      fmt_key("ENTER", "Accept mask") .. " " .. fmt_key("ESC", "Cancel mask") .. " " .. fmt_key("SHIFT+I", canvas_state),
      fmt_key("HOME/END", "Shift selection") .. " " .. fmt_key("C", "Clear selection") .. " " .. fmt_key("Z", "High visibility")
    }
    if self.active_shape then
      local mask_state = ('Invert shape (%s)'):format(self.active_shape.inverted and 'black' or 'white')
      extend_table(lines, {
        fmt_key("I", mask_state) .. " "  .. fmt_key("G", "Grab") .. " " .. fmt_key("PGUP/PGDWN", "Adjust order"),
        fmt_key("X", "Remove point") .. " " .. fmt_key("DEL", "Remove shape") .. " " .. fmt_key("B/SHIFT+B", ("Adjust blur (%d)"):format(self.active_shape.blur)),
      })
    else
      extend_table(lines, {
        fmt_key("CLICK", "Select/Create shape")
      })
    end

    local full_line = table.concat(lines, "\\N")
    ass:append(full_line)


    local white_bars = {}
    local black_bars = {}
    local arrow_x = nil

    local bar_y = 5 + #lines * self.text_size + 5
    local bar_x = self.display_state.screen.width - 5

    for i, shape in ipairs(self.mask_shapes) do
      local target_table = shape.inverted and black_bars or white_bars

      if shape == self.active_shape then
        arrow_x = bar_x - 3/2
      end

      target_table[#target_table+1] = bar_x

      bar_x = bar_x - 5
    end

    ass:new_event()
    ass:pos(0,0)
    ass:append( ('{\\bord0\\1c&H%02X%02X%02X&}'):format(255,255,255))
    ass:draw_start()

    if arrow_x then
      ass:move_to(arrow_x,   bar_y+7+2)
      ass:line_to(arrow_x+2, bar_y+7+2+3)
      ass:line_to(arrow_x-2, bar_y+7+2+3)
    end
    for i, x in ipairs(white_bars) do
      ass:rect_cw(x-3, bar_y, x, bar_y+7)
    end

    ass:new_event()
    ass:pos(0,0)
    ass:append( ('{\\bord0\\1c&H%02X%02X%02X&}'):format(64,64,64))
    ass:draw_start()

    for i, x in ipairs(black_bars) do
      ass:rect_cw(x-3, bar_y, x, bar_y+7)
    end

  end

  return ass.text
end


function ASSMasker:render_mask_data(mask_data, w, h, file_path)
  local ass_text = self:mask_data_to_ass(mask_data, w,h)

  local c = mask_data.inverted and 255 or 0

  local mpv_args = {
    'mpv',
    '--msg-level=all=no',
    '--no-config',

    '--sub-file=memory://' .. ass_text,
    ('av://lavfi:color=color=#%02X%02X%02X:size=%dx%d:duration=1,format=rgb24'):format(
      c,c,c,
      w, h
    ),
    '--frames=1',

    '--of=png',
    '--ovc=png',

   '-o', file_path
  }

  local ret = utils.subprocess({args=mpv_args, cancellable=false})
  return ret
end


function ASSMasker:mask_data_to_ass(mask_data, w, h)
  local ass = assdraw.ass_new()

  for i, shape in ipairs(mask_data.shapes) do
    ass:new_event()
    ass:pos(0, 0)
    if shape.inverted then
      ass:append( ('{\\bord0\\1c&H%02X%02X%02X&}'):format(0,0,0) )
    else
      ass:append( ('{\\bord0\\1c&H%02X%02X%02X&}'):format(255,255,255) )
    end
    if shape.blur > 0 then
      ass:append(('{\\blur%f}'):format(shape.blur))
    end
    ass:draw_start()

    for i, point in ipairs(shape.points) do
      if i == 1 then
        ass:move_to(point.x, point.y)
      else
        ass:line_to(point.x, point.y)
      end
    end

  end
  local ass_text = 'Dialogue: 0,0:00:00.00,0:99:00.00,Default,,0,0,0,,' .. ass.text:gsub('\n', '\nDialogue: 0,0:00:00.00,0:99:00.00,Default,,0,0,0,,')

  local ass_header = ([[[Script Info]
Title: Temporary file
ScriptType: v4.00+
PlayResX: %d
PlayResY: %d

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,80,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
]]):format(w, h)

  return ass_header .. ass_text
end
