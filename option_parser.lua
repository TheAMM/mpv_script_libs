--[[
  A slightly more advanced option parser for scripts.
  It supports documenting the options, and can export an example config.
  It also can rewrite the config file with overrides, preserving the
  original lines and appending changes to the end, along with profiles.

  Does not depend on other libs.
]]--

local OptionParser = {}
OptionParser.__index = OptionParser

setmetatable(OptionParser, {
  __call = function (cls, ...) return cls.new(...) end
})

function OptionParser.new(identifier, shorthand_identifier)
  local self = setmetatable({}, OptionParser)

  self.identifier = identifier
  self.shorthand_identifier = shorthand_identifier

  self.config_file = self:_get_config_file(identifier)

  self.OVERRIDE_START = "# Script-saved overrides below this line. Edits will be lost!"

  -- All the options contained, as a list
  self.options_list = {}
  -- All the options contained, as a table with keys. See add_option
  self.options = {}

  self.default_profile = {name = "default", values = {}, loaded={}, config_lines = {}}
  self.profiles = {}

  self.active_profile = self.default_profile

  -- Recusing metatable magic to wrap self.values.key.sub_key into
  -- self.options["key.sub_key"].value, with support for assignments as well
  function get_value_or_mapper(key)
    local cur_option = self.options[key]

    if cur_option then
      -- Wrap tables
      if cur_option.type == "table" then
        return setmetatable({}, {
          __index = function(t, sub_key)
            return get_value_or_mapper(key .. "." .. sub_key)
          end,
          __newindex = function(t, sub_key, value)
            local sub_option = self.options[key .. "." .. sub_key]
            if sub_option and sub_option.type ~= "table" then
              self.active_profile.values[key .. "." .. sub_key] = value
            end
          end
        })
      else
        return self.active_profile.values[key]
      end
    end
  end

  -- Same recusing metatable magic to get the .default
  function get_default_or_mapper(key)
    local cur_option = self.options[key]

    if cur_option then
      if cur_option.type == "table" then
        return setmetatable({}, {
          __index = function(t, sub_key)
            return get_default_or_mapper(key .. "." .. sub_key)
          end,
        })
      else
        return cur_option.default
        -- return self.active_profile.values[key]
      end
    end
  end

  -- Easy lookups for values and defaults
  self.values = setmetatable({}, {
    __index = function(t, key)
      return get_value_or_mapper(key)
    end,
    __newindex = function(t, key, value)
      local option = self.options[key]
      if option then
        -- option.value = value
        self.active_profile.values[key] = value
      end
    end
  })

  self.defaults = setmetatable({}, {
    __index = function(t, key)
      return get_default_or_mapper(key)
    end
  })

  -- Hacky way to run after the script is initialized and options (hopefully) added
  mp.add_timeout(0, function()
    local get_opt_shorthand = function(key)
      return mp.get_opt(self.identifier .. "-" .. key) or (self.shorthand_identifier and mp.get_opt(self.shorthand_identifier .. "-" .. key))
    end

    -- Handle a '--script-opts identifier-example-config=example.conf' to save an example config to a file
    local example_dump_filename = get_opt_shorthand("example-config")
    if example_dump_filename then
      self:save_example_options(example_dump_filename)
    end

    local explain_config = get_opt_shorthand("explain-config")
    if explain_config then
      self:explain_options()
    end

    if (example_dump_filename or explain_config) and mp.get_property_native("options/idle") then
        msg.info("Exiting.")
        mp.commandv("quit")
      end
  end)

  return self
end

function OptionParser:activate_profile(profile_name)
  local chosen_profile = nil
  if profile_name then
    for i, profile in ipairs(self.profiles) do
      if profile.name == profile_name then
        chosen_profile = profile
        break
      end
    end
  else
    chosen_profile = self.default_profile
  end

  if chosen_profile then
    self.active_profile = chosen_profile
  end

end

function OptionParser:add_option(key, default, description, pad_before)
  if self.options[key] ~= nil then
    -- Already exists!
    return nil
  end

  local option_index = #self.options_list + 1
  local option_type = type(default)

  -- Check if option is an array
  if option_type == "table" then
    if default._array then
      option_type = "array"
    end
    default._array = nil
  end

  local option = {
    index = option_index,
    type = option_type,
    key = key,
    default = default,

    description = description,
    pad_before = pad_before
  }

  self.options_list[option_index] = option

  -- table-options are just containers for sub-options and have no value
  if option_type == "table" then
    option.default = nil

    -- Add sub-options
    for i, sub_option_data in ipairs(default) do
      local sub_key = sub_option_data[1]
      sub_option_data[1] = key .. "." .. sub_key
      local sub_option = self:add_option(unpack(sub_option_data))
    end
  end

  if key then
    self.options[key] = option
    self.default_profile.values[option.key] = option.default
  end

  return option
end


function OptionParser:add_options(list_of_options)
  for i, option_args in ipairs(list_of_options) do
    self:add_option(unpack(option_args))
  end
end


function OptionParser:restore_defaults()
  for key, option in pairs(self.options) do
    if option.type ~= "table" then
      self.active_profile.values[option.key] = option.default
    end
  end
end

function OptionParser:restore_loaded()
  for key, option in pairs(self.options) do
    if option.type ~= "table" then
      -- Non-default profiles will have an .loaded entry for all options
      local value = self.active_profile.loaded[option.key]
      if value == nil then value = option.default end
      self.active_profile.values[option.key] = value
    end
  end
end


function OptionParser:_get_config_file(identifier)
  local config_filename = "script-opts/" .. identifier .. ".conf"
  local config_file = mp.find_config_file(config_filename)

  if not config_file then
    config_filename = "lua-settings/" .. identifier .. ".conf"
    config_file = mp.find_config_file(config_filename)

    if config_file then
      msg.warn("lua-settings/ is deprecated, use directory script-opts/")
    end
  end

  return config_file
end


function OptionParser:value_to_string(value)
  if type(value) == "boolean" then
    if value then value = "yes" else value = "no" end
  elseif type(value) == "table" then
    return utils.format_json(value)
  end
  return tostring(value)
end


function OptionParser:string_to_value(option_type, value)
  if option_type == "boolean" then
    if value == "yes" or value == "true" then
      value = true
    elseif value == "no" or value == "false" then
      value = false
    else
      -- can't parse as boolean
      value = nil
    end
  elseif option_type == "number" then
    value = tonumber(value)
    if value == nil then
      -- Can't parse as number
    end
  elseif option_type == "array" then
    value = utils.parse_json(value)
  end
  return value
end


function OptionParser:get_profile(profile_name)
  for i, profile in ipairs(self.profiles) do
    if profile.name == profile_name then
      return profile
    end
  end
end


function OptionParser:create_profile(profile_name, base_on_original)
  if not self:get_profile(profile_name) then
    new_profile = {name = profile_name, values={}, loaded={}, config_lines={}}

    if base_on_original then
      -- Copy values from default config
      for k, v in pairs(self.default_profile.values) do
        new_profile.values[k] = v
      end
      for k, v in pairs(self.default_profile.loaded) do
        new_profile.loaded[k] = v
      end
    else
      -- Copy current values, but not loaded
      for k, v in pairs(self.active_profile.values) do
        new_profile.values[k] = v
      end
    end

    table.insert(self.profiles, new_profile)
    return new_profile
  end
end


function OptionParser:load_options()

  local trim = function(text)
    return (text:gsub("^%s*(.-)%s*$", "%1"))
  end

  local script_opts_parsed = false
  -- Function to parse --script-opts with. Defined here, so we can call it at multiple possible situations
  local parse_script_opts = function()
    if script_opts_parsed then return end

    -- Checks if the given key starts with identifier or the shorthand_identifier and returns the prefix-less key
    local check_prefix = function(key)
      if key:find(self.identifier .. "-", 1, true) then
        return key:sub(self.identifier:len()+2)
      elseif key:find(self.shorthand_identifier .. "-", 1, true) then
        return key:sub(self.shorthand_identifier:len()+2)
      end
    end

    for key, value in pairs(mp.get_property_native("options/script-opts")) do
      key = check_prefix(key)
      if key then
        -- Handle option value, trimmed down version of the above file reading
        key = trim(key)
        value = trim(value)

        local option = self.options[key]
        if not option then
          if not (key == 'example-config' or key == 'explain-config') then
            msg.warn(("script-opts: ignoring unknown key '%s'"):format(key))
          end
        elseif option.type == "table" then
            msg.warn(("script-opts: ignoring value for table-option %s"):format(key))
        else
          local parsed_value = self:string_to_value(option.type, value)

          if parsed_value == nil then
            msg.error(("script-opts: error parsing value '%s' for key '%s' (as %s)"):format(value, key, option.type))
          else
            self.default_profile.values[option.key] = parsed_value
            self.default_profile.loaded[option.key] = parsed_value
          end
        end
      end
    end

    script_opts_parsed = true
  end

  local file = self.config_file and io.open(self.config_file, 'r')
  if not file then
    parse_script_opts()
    return
  end

  local current_profile = self.default_profile
  local override_reached = false
  local line_index = 1

  -- Read all lines in advance
  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()

  local total_lines = #lines

  while line_index < total_lines + 1 do
    local line = lines[line_index]

    local profile_name = line:match("^%[(..-)%]$")

    if line == self.OVERRIDE_START then
      override_reached = true

    elseif line:find("#") == 1 then
      -- Skip comments
    elseif profile_name then
      -- Profile potentially changing, parse script-opts
      parse_script_opts()
      current_profile = self:get_profile(profile_name) or self:create_profile(profile_name, true)
      override_reached = false

    else
      local key, value = line:match("^(..-)=(.+)$")
      if key then
        key = trim(key)
        value = trim(value)

        local option = self.options[key]
        if not option then
          msg.warn(("%s:%d ignoring unknown key '%s'"):format(self.config_file, line_index, key))
        elseif option.type == "table" then
            msg.warn(("%s:%d ignoring value for table-option %s"):format(self.config_file, line_index, key))
        else
          -- If option is an array, make sure we read all lines
          if option.type == "array" then
            local start_index = line_index
            -- Read lines until one ends with ]
            while not value:match("%]%s*$") do
              line_index = line_index + 1
              if line_index > total_lines then
                msg.error(("%s:%d non-ending %s for key '%s'"):format(self.config_file, start_index, option.type, key))
              end
              value = value .. trim(lines[line_index])
            end
          end
          local parsed_value = self:string_to_value(option.type, value)

          if parsed_value == nil then
            msg.error(("%s:%d error parsing value '%s' for key '%s' (as %s)"):format(self.config_file, line_index, value, key, option.type))
          else
            current_profile.values[option.key] = parsed_value
            if not override_reached then
              current_profile.loaded[option.key] = parsed_value
            end
          end
        end
      end
    end

    if not override_reached and not profile_name then
      table.insert(current_profile.config_lines, line)
    end

    line_index = line_index + 1
  end

  -- Parse --script-opts if they weren't already
  parse_script_opts()

end


function OptionParser:save_options()
  if not self.config_file then return nil, "no configuration file found" end

  local file = io.open(self.config_file, 'w')
  if not file then return nil, "unable to open configuration file for writing" end

  local profiles = {self.default_profile}
  for i, profile in ipairs(self.profiles) do
    table.insert(profiles, profile)
  end

  local out_lines = {}

  local add_linebreak = function()
    if out_lines[#out_lines] ~= '' then
      table.insert(out_lines, '')
    end
  end

  for profile_index, profile in ipairs(profiles) do

    local profile_override_lines = {}
    for option_index, option in ipairs(self.options_list) do
      local option_value = profile.values[option.key]
      local option_loaded = profile.loaded[option.key]

      if option_loaded == nil then
        option_loaded = self.default_profile.loaded[option.key]
      end
      if option_loaded == nil then
        option_loaded = option.default
      end

      -- If value is different from default AND loaded value, store it in array
      if option.key then
        if (option_value ~= option_loaded) then
          table.insert(profile_override_lines, ('%s=%s'):format(option.key, self:value_to_string(option_value)))
        end
      end
    end

    if (#profile.config_lines > 0 or #profile_override_lines > 0) and profile ~= self.default_profile then
      -- Write profile name, if this is not default profile
      add_linebreak()
      table.insert(out_lines, ("[%s]"):format(profile.name))
    end

    -- Write original config lines
    for line_index, line in ipairs(profile.config_lines) do
      table.insert(out_lines, line)
    end
    -- end

    if #profile_override_lines > 0 then
      -- Add another newline before the override comment, if needed
      add_linebreak()

      table.insert(out_lines, self.OVERRIDE_START)
      for override_line_index, override_line in ipairs(profile_override_lines) do
        table.insert(out_lines, override_line)
      end
    end

  end

  -- Add a final linebreak if needed
  add_linebreak()

  file:write(table.concat(out_lines, "\n"))
  file:close()

  return true
end


function OptionParser:get_default_config_lines()
  local example_config_lines = {}

  for option_index, option in ipairs(self.options_list) do
    if option.pad_before then
      table.insert(example_config_lines, '')
    end

    if option.description then
      for description_line in option.description:gmatch('[^\r\n]+') do
        table.insert(example_config_lines, ('# ' .. description_line))
      end
    end
    if option.key and option.type ~= "table" then
      table.insert(example_config_lines, ('%s=%s'):format(option.key, self:value_to_string(option.default)) )
    end
  end
  return example_config_lines
end


function OptionParser:explain_options()
  local example_config_lines = self:get_default_config_lines()
  msg.info(table.concat(example_config_lines, '\n'))
end


function OptionParser:save_example_options(filename)
  local file = io.open(filename, "w")
  if not file then
    msg.error("Unable to open file '" .. filename .. "' for writing")
  else
    local example_config_lines = self:get_default_config_lines()
    file:write(table.concat(example_config_lines, '\n'))
    file:close()
    msg.info("Wrote example config to file '" .. filename .. "'")
  end
end
