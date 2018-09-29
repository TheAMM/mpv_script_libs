--[[
  Assorted helper functions, from checking falsey values to path utils
  to escaping and wrapping strings.

  Does not depend on other libs.
]]--

local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

-- Determine platform --
ON_WINDOWS = (package.config:sub(1,1) ~= '/')

-- Some helper functions needed to parse the options --
function isempty(v) return (v == false) or (v == nil) or (v == "") or (v == 0) or (type(v) == "table" and next(v) == nil) end

function divmod (a, b)
  return math.floor(a / b), a % b
end

-- Better modulo
function bmod( i, N )
  return (i % N + N) % N
end


-- Path utils
local path_utils = {
  abspath    = true,
  split      = true,
  dirname    = true,
  basename   = true,

  isabs      = true,
  normcase   = true,
  splitdrive = true,
  join       = true,
  normpath   = true,
  relpath    = true,
}

-- Helpers
path_utils._split_parts = function(path, sep)
  local path_parts = {}
  for c in path:gmatch('[^' .. sep .. ']+') do table.insert(path_parts, c) end
  return path_parts
end

-- Common functions
path_utils.abspath = function(path)
  if not path_utils.isabs(path) then
    local cwd = os.getenv("PWD") or utils.getcwd()
    path = path_utils.join(cwd, path)
  end
  return path_utils.normpath(path)
end

path_utils.split = function(path)
  local drive, path = path_utils.splitdrive(path)
  -- Technically unix path could contain a \, but meh
  local first_index, last_index = path:find('^.*[/\\]')

  if last_index == nil then
    return drive .. '', path
  else
    local head = path:sub(0, last_index-1)
    local tail = path:sub(last_index+1)
    if head == '' then head = sep end
    return drive .. head, tail
  end
end

path_utils.dirname = function(path)
  local head, tail = path_utils.split(path)
  return head
end

path_utils.basename = function(path)
  local head, tail = path_utils.split(path)
  return tail
end

path_utils.expanduser = function(path)
  -- Expands the following from the start of the path:
  -- ~ to HOME
  -- ~~ to mpv config directory (first result of mp.find_config_file('.'))
  -- ~~desktop to Windows desktop, otherwise HOME
  -- ~~temp to Windows temp or /tmp/

  local first_index, last_index = path:find('^.-[/\\]')
  local head = path
  local tail = ''

  local sep = ''

  if last_index then
    head = path:sub(0, last_index-1)
    tail = path:sub(last_index+1)
    sep  = path:sub(last_index, last_index)
  end

  if head == "~~desktop" then
    head = ON_WINDOWS and path_utils.join(os.getenv('USERPROFILE'), 'Desktop') or os.getenv('HOME')
  elseif head == "~~temp" then
    head = ON_WINDOWS and os.getenv('TEMP') or (os.getenv('TMP') or '/tmp/')
  elseif head == "~~" then
    local mpv_config_dir = mp.find_config_file('.')
    if mpv_config_dir then
      head = path_utils.dirname(mpv_config_dir)
    else
      msg.warn('Could not find mpv config directory (using mp.find_config_file), using temp instead')
      head = ON_WINDOWS and os.getenv('TEMP') or (os.getenv('TMP') or '/tmp/')
    end
  elseif head == "~" then
    head = ON_WINDOWS and os.getenv('USERPROFILE') or os.getenv('HOME')
  end

  return path_utils.normpath(path_utils.join(head .. sep, tail))
end


if ON_WINDOWS then
  local sep = '\\'
  local altsep = '/'
  local curdir = '.'
  local pardir = '..'
  local colon = ':'

  local either_sep = function(c) return c == sep or c == altsep end

  path_utils.isabs = function(path)
    local prefix, path = path_utils.splitdrive(path)
    return either_sep(path:sub(1,1))
  end

  path_utils.normcase = function(path)
    return path:gsub(altsep, sep):lower()
  end

  path_utils.splitdrive = function(path)
    if #path >= 2 then
      local norm = path:gsub(altsep, sep)
      if (norm:sub(1, 2) == (sep..sep)) and (norm:sub(3,3) ~= sep) then
        -- UNC path
        local index = norm:find(sep, 3)
        if not index then
          return '', path
        end

        local index2 = norm:find(sep, index + 1)
        if index2 == index + 1 then
          return '', path
        elseif not index2 then
          index2 = path:len()
        end

        return path:sub(1, index2-1), path:sub(index2)
      elseif norm:sub(2,2) == colon then
        return path:sub(1, 2), path:sub(3)
      end
    end
    return '', path
  end

  path_utils.join = function(path, ...)
    local paths = {...}

    local result_drive, result_path = path_utils.splitdrive(path)

    function inner(p)
      local p_drive, p_path = path_utils.splitdrive(p)
      if either_sep(p_path:sub(1,1)) then
        -- Path is absolute
        if p_drive ~= '' or result_drive == '' then
          result_drive = p_drive
        end
        result_path = p_path
        return
      elseif p_drive ~= '' and p_drive ~= result_drive then
        if p_drive:lower() ~= result_drive:lower() then
          -- Different paths, ignore first
          result_drive = p_drive
          result_path = p_path
          return
        end
      end

      if result_path ~= '' and not either_sep(result_path:sub(-1)) then
        result_path = result_path .. sep
      end
      result_path = result_path .. p_path
    end

    for i, p in ipairs(paths) do inner(p) end

    -- add separator between UNC and non-absolute path
    if result_path ~= '' and not either_sep(result_path:sub(1,1)) and
      result_drive ~= '' and result_drive:sub(-1) ~= colon then
      return result_drive .. sep .. result_path
    end
    return result_drive .. result_path
  end

  path_utils.normpath = function(path)
    if path:find('\\\\.\\', nil, true) == 1 or path:find('\\\\?\\', nil, true) == 1 then
      -- Device names and literal paths - return as-is
      return path
    end

    path = path:gsub(altsep, sep)
    local prefix, path = path_utils.splitdrive(path)

    if path:find(sep) == 1 then
      prefix = prefix .. sep
      path = path:gsub('^[\\]+', '')
    end

    local comps = path_utils._split_parts(path, sep)

    local i = 1
    while i <= #comps do
      if comps[i] == curdir then
        table.remove(comps, i)
      elseif comps[i] == pardir then
        if i > 1 and comps[i-1] ~= pardir then
          table.remove(comps, i)
          table.remove(comps, i-1)
          i = i - 1
        elseif i == 1 and prefix:match('\\$') then
          table.remove(comps, i)
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end

    if prefix == '' and #comps == 0 then
      comps[1] = curdir
    end

    return prefix .. table.concat(comps, sep)
  end

  path_utils.relpath = function(path, start)
    start = start or curdir

    local start_abs = path_utils.abspath(path_utils.normpath(start))
    local path_abs = path_utils.abspath(path_utils.normpath(path))

    local start_drive, start_rest = path_utils.splitdrive(start_abs)
    local path_drive, path_rest = path_utils.splitdrive(path_abs)

    if path_utils.normcase(start_drive) ~= path_utils.normcase(path_drive) then
      -- Different drives
      return nil
    end

    local start_list = path_utils._split_parts(start_rest, sep)
    local path_list = path_utils._split_parts(path_rest, sep)

    local i = 1
    for j = 1, math.min(#start_list, #path_list) do
      if path_utils.normcase(start_list[j]) ~= path_utils.normcase(path_list[j]) then
        break
      end
      i = j + 1
    end

    local rel_list = {}
    for j = 1, (#start_list - i + 1) do rel_list[j] = pardir end
    for j = i, #path_list do table.insert(rel_list, path_list[j]) end

    if #rel_list == 0 then
      return curdir
    end

    return path_utils.join(unpack(rel_list))
  end

else
  -- LINUX
  local sep = '/'
  local curdir = '.'
  local pardir = '..'

  path_utils.isabs = function(path) return path:sub(1,1) == '/' end
  path_utils.normcase = function(path) return path end
  path_utils.splitdrive = function(path) return '', path end

  path_utils.join = function(path, ...)
    local paths = {...}

    for i, p in ipairs(paths) do
      if p:sub(1,1) == sep then
        path = p
      elseif path == '' or path:sub(-1) == sep then
        path = path .. p
      else
        path = path .. sep .. p
      end
    end

    return path
  end

  path_utils.normpath = function(path)
    if path == '' then return curdir end

    local initial_slashes = (path:sub(1,1) == sep) and 1
    if initial_slashes and path:sub(2,2) == sep and path:sub(3,3) ~= sep then
      initial_slashes = 2
    end

    local comps = path_utils._split_parts(path, sep)
    local new_comps = {}

    for i, comp in ipairs(comps) do
      if comp == '' or comp == curdir then
        -- pass
      elseif (comp ~= pardir or (not initial_slashes and #new_comps == 0) or
        (#new_comps > 0 and new_comps[#new_comps] == pardir)) then
        table.insert(new_comps, comp)
      elseif #new_comps > 0 then
        table.remove(new_comps)
      end
    end

    comps = new_comps
    path = table.concat(comps, sep)
    if initial_slashes then
      path = sep:rep(initial_slashes) .. path
    end

    return (path ~= '') and path or curdir
  end

  path_utils.relpath = function(path, start)
    start = start or curdir

    local start_abs = path_utils.abspath(path_utils.normpath(start))
    local path_abs = path_utils.abspath(path_utils.normpath(path))

    local start_list = path_utils._split_parts(start_abs, sep)
    local path_list = path_utils._split_parts(path_abs, sep)

    local i = 1
    for j = 1, math.min(#start_list, #path_list) do
      if start_list[j] ~= path_list[j] then break
      end
      i = j + 1
    end

    local rel_list = {}
    for j = 1, (#start_list - i + 1) do rel_list[j] = pardir end
    for j = i, #path_list do table.insert(rel_list, path_list[j]) end

    if #rel_list == 0 then
      return curdir
    end

    return path_utils.join(unpack(rel_list))
  end

end
-- Path utils end

-- Check if path is local (by looking if it's prefixed by a proto://)
local path_is_local = function(path)
  local proto = path:match('(..-)://')
  return proto == nil
end


function Set(source)
  local set = {}
  for _, l in ipairs(source) do set[l] = true end
  return set
end

---------------------------
-- More helper functions --
---------------------------

function busy_wait(seconds)
  local target = mp.get_time() + seconds
  local cycles = 0
  while target > mp.get_time() do
    cycles = cycles + 1
  end
  return cycles
end

-- Removes all keys from a table, without destroying the reference to it
function clear_table(target)
  for key, value in pairs(target) do
    target[key] = nil
  end
end
function shallow_copy(target)
  if type(target) == "table" then
    local copy = {}
    for k, v in pairs(target) do
      copy[k] = v
    end
    return copy
  else
    return target
  end
end

function deep_copy(target)
  local copy = {}
  for k, v in pairs(target) do
    if type(v) == "table" then
      copy[k] = deep_copy(v)
    else
      copy[k] = v
    end
  end
  return copy
end

-- Rounds to given decimals. eg. round_dec(3.145, 0) => 3
function round_dec(num, idp)
  local mult = 10^(idp or 0)
  return math.floor(num * mult + 0.5) / mult
end

function file_exists(name)
  local f = io.open(name, "rb")
  if f ~= nil then
    local ok, err, code = f:read(1)
    io.close(f)
    return code == nil
  else
    return false
  end
end

function path_exists(name)
  local f = io.open(name, "rb")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

function create_directories(path)
  local cmd
  if ON_WINDOWS then
    cmd = { args = {'cmd', '/c', 'mkdir', path} }
  else
    cmd = { args = {'mkdir', '-p', path} }
  end
  utils.subprocess(cmd)
end

function move_file(source_path, target_path)
  local cmd
  if ON_WINDOWS then
    cmd = { cancellable=false, args = {'cmd', '/c', 'move', '/Y', source_path, target_path } }
    utils.subprocess(cmd)
  else
    -- cmd = { cancellable=false, args = {'mv', source_path, target_path } }
    os.rename(source_path, target_path)
  end
end

function check_pid(pid)
  -- Checks if a PID exists and returns true if so
  local cmd, r
  if ON_WINDOWS then
    cmd = { cancellable=false, args = {
      'tasklist', '/FI', ('PID eq %d'):format(pid)
    }}
    r = utils.subprocess(cmd)
    return r.stdout:sub(1,1) == '\13'
  else
    cmd = { cancellable=false, args = {
      'sh', '-c', ('kill -0 %d 2>/dev/null'):format(pid)
    }}
    r = utils.subprocess(cmd)
    return r.status == 0
  end
end

function kill_pid(pid)
  local cmd, r
  if ON_WINDOWS then
    cmd = { cancellable=false, args = {'taskkill', '/F', '/PID', tostring(pid) } }
  else
    cmd = { cancellable=false, args = {'kill', tostring(pid) } }
  end
  r = utils.subprocess(cmd)
  return r.status == 0, r
end


-- Find an executable in PATH or CWD with the given name
function find_executable(name)
  local delim = ON_WINDOWS and ";" or ":"

  local pwd = os.getenv("PWD") or utils.getcwd()
  local path = os.getenv("PATH")

  local env_path = pwd .. delim .. path -- Check CWD first

  local result, filename
  for path_dir in env_path:gmatch("[^"..delim.."]+") do
    filename = path_utils.join(path_dir, name)
    if file_exists(filename) then
      result = filename
      break
    end
  end

  return result
end

local ExecutableFinder = { path_cache = {} }
-- Searches for an executable and caches the result if any
function ExecutableFinder:get_executable_path( name, raw_name )
  name = ON_WINDOWS and not raw_name and (name .. ".exe") or name

  if self.path_cache[name] == nil then
    self.path_cache[name] = find_executable(name) or false
  end
  return self.path_cache[name]
end

-- Format seconds to HH.MM.SS.sss
function format_time(seconds, sep, decimals)
  decimals = decimals == nil and 3 or decimals
  sep = sep and sep or ":"
  local s = seconds
  local h, s = divmod(s, 60*60)
  local m, s = divmod(s, 60)

  local second_format = string.format("%%0%d.%df", 2+(decimals > 0 and decimals+1 or 0), decimals)

  return string.format("%02d"..sep.."%02d"..sep..second_format, h, m, s)
end

-- Format seconds to 1h 2m 3.4s
function format_time_hms(seconds, sep, decimals, force_full)
  decimals = decimals == nil and 1 or decimals
  sep = sep ~= nil and sep or " "

  local s = seconds
  local h, s = divmod(s, 60*60)
  local m, s = divmod(s, 60)

  if force_full or h > 0 then
    return string.format("%dh"..sep.."%dm"..sep.."%." .. tostring(decimals) .. "fs", h, m, s)
  elseif m > 0 then
    return string.format("%dm"..sep.."%." .. tostring(decimals) .. "fs", m, s)
  else
    return string.format("%." .. tostring(decimals) .. "fs", s)
  end
end

-- Writes text on OSD and console
function log_info(txt, timeout)
  timeout = timeout or 1.5
  msg.info(txt)
  mp.osd_message(txt, timeout)
end

-- Join table items, ala ({"a", "b", "c"}, "=", "-", ", ") => "=a-, =b-, =c-"
function join_table(source, before, after, sep)
  before = before or ""
  after = after or ""
  sep = sep or ", "
  local result = ""
  for i, v in pairs(source) do
    if not isempty(v) then
      local part = before .. v .. after
      if i == 1 then
        result = part
      else
        result = result .. sep .. part
      end
    end
  end
  return result
end

function wrap(s, char)
  char = char or "'"
  return char .. s .. char
end
-- Wraps given string into 'string' and escapes any 's in it
function escape_and_wrap(s, char, replacement)
  char = char or "'"
  replacement = replacement or "\\" .. char
  return wrap(string.gsub(s, char, replacement), char)
end
-- Escapes single quotes in a string and wraps the input in single quotes
function escape_single_bash(s)
  return escape_and_wrap(s, "'", "'\\''")
end

-- Returns (a .. b) if b is not empty or nil
function joined_or_nil(a, b)
  return not isempty(b) and (a .. b) or nil
end

-- Put items from one table into another
function extend_table(target, source)
  for i, v in pairs(source) do
    table.insert(target, v)
  end
end

-- Creates a handle and filename for a temporary random file (in current directory)
function create_temporary_file(base, mode, suffix)
  local handle, filename
  suffix = suffix or ""
  while true do
    filename = base .. tostring(math.random(1, 5000)) .. suffix
    handle = io.open(filename, "r")
    if not handle then
      handle = io.open(filename, mode)
      break
    end
    io.close(handle)
  end
  return handle, filename
end


function get_processor_count()
  local proc_count

  if ON_WINDOWS then
    proc_count = tonumber(os.getenv("NUMBER_OF_PROCESSORS"))
  else
    local cpuinfo_handle = io.open("/proc/cpuinfo")
    if cpuinfo_handle ~= nil then
      local cpuinfo_contents = cpuinfo_handle:read("*a")
      local _, replace_count = cpuinfo_contents:gsub('processor', '')
      proc_count = replace_count
    end
  end

  if proc_count and proc_count > 0 then
      return proc_count
  else
    return nil
  end
end

function substitute_values(string, values)
  local substitutor = function(match)
    if match == "%" then
       return "%"
    else
      -- nil is discarded by gsub
      return values[match]
    end
  end

  local substituted = string:gsub('%%(.)', substitutor)
  return substituted
end

-- ASS HELPERS --
function round_rect_top( ass, x0, y0, x1, y1, r )
  local c = 0.551915024494 * r -- circle approximation
  ass:move_to(x0 + r, y0)
  ass:line_to(x1 - r, y0) -- top line
  if r > 0 then
      ass:bezier_curve(x1 - r + c, y0, x1, y0 + r - c, x1, y0 + r) -- top right corner
  end
  ass:line_to(x1, y1) -- right line
  ass:line_to(x0, y1) -- bottom line
  ass:line_to(x0, y0 + r) -- left line
  if r > 0 then
      ass:bezier_curve(x0, y0 + r - c, x0 + r - c, y0, x0 + r, y0) -- top left corner
  end
end

function round_rect(ass, x0, y0, x1, y1, rtl, rtr, rbr, rbl)
    local c = 0.551915024494
    ass:move_to(x0 + rtl, y0)
    ass:line_to(x1 - rtr, y0) -- top line
    if rtr > 0 then
        ass:bezier_curve(x1 - rtr + rtr*c, y0, x1, y0 + rtr - rtr*c, x1, y0 + rtr) -- top right corner
    end
    ass:line_to(x1, y1 - rbr) -- right line
    if rbr > 0 then
        ass:bezier_curve(x1, y1 - rbr + rbr*c, x1 - rbr + rbr*c, y1, x1 - rbr, y1) -- bottom right corner
    end
    ass:line_to(x0 + rbl, y1) -- bottom line
    if rbl > 0 then
        ass:bezier_curve(x0 + rbl - rbl*c, y1, x0, y1 - rbl + rbl*c, x0, y1 - rbl) -- bottom left corner
    end
    ass:line_to(x0, y0 + rtl) -- left line
    if rtl > 0 then
        ass:bezier_curve(x0, y0 + rtl - rtl*c, x0 + rtl - rtl*c, y0, x0 + rtl, y0) -- top left corner
    end
end
