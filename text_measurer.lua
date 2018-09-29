--[[
	TextMeasurer can calculate character and text width with medium accuracy,
	and wrap/truncate strings by the information.
	It works by creating an ASS subtitle, rendering it with a subprocessed mpv
	and then counting pixels to find the bounding boxes for individual characters.
]]--

local TextMeasurer = {
	FONT_HEIGHT = 16 * 5,
	FONT_MARGIN = 5,
	BASE_X = 10,

	IMAGE_WIDTH = 256,

	FONT_NAME = 'sans-serif',

	CHARACTERS = {
		'', 'M ', -- For measuring, removed later
		'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
		'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
		'!', '"', '#', '$', '%', '&', "'", '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~',
		'\195\161', '\195\129', '\195\160', '\195\128', '\195\162', '\195\130', '\195\164', '\195\132', '\195\163', '\195\131', '\195\165', '\195\133', '\195\166',
		'\195\134', '\195\167', '\195\135', '\195\169', '\195\137', '\195\168', '\195\136', '\195\170', '\195\138', '\195\171', '\195\139', '\195\173', '\195\141',
		'\195\172', '\195\140', '\195\174', '\195\142', '\195\175', '\195\143', '\195\177', '\195\145', '\195\179', '\195\147', '\195\178', '\195\146', '\195\180',
		'\195\148', '\195\182', '\195\150', '\195\181', '\195\149', '\195\184', '\195\152', '\197\147', '\197\146', '\195\159', '\195\186', '\195\154', '\195\185',
		'\195\153', '\195\187', '\195\155', '\195\188', '\195\156'
	},

	WIDTH_MAP = nil,

	ASS_HEADER = [[[Script Info]
Title: Temporary file
ScriptType: v4.00+
PlayResX: %d
PlayResY: %d

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,%s,80,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
]]
}

TextMeasurer.LINE_HEIGHT = (TextMeasurer.FONT_HEIGHT + TextMeasurer.FONT_MARGIN)
TextMeasurer.TOTAL_HEIGHT = TextMeasurer.LINE_HEIGHT * #TextMeasurer.CHARACTERS


function TextMeasurer:create_ass_track()
	local ass_lines = { self.ASS_HEADER:format(self.IMAGE_WIDTH, self.TOTAL_HEIGHT, self.FONT_NAME) }

	for i, character in ipairs(self.CHARACTERS) do
		local ass_line = 'Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,' .. ('{\\pos(%d, %d)}%sM'):format(self.BASE_X, (i-1) * self.LINE_HEIGHT, character)
		table.insert(ass_lines, ass_line)
	end

	return table.concat(ass_lines, '\n')
end


function TextMeasurer:render_ass_track(ass_sub_data)
	-- Round up to divisible by 2
	local target_height = self.TOTAL_HEIGHT + (self.TOTAL_HEIGHT + 2) % 2

	local mpv_args = {
		'mpv',
		'--msg-level=all=no',

		'--sub-file=memory://' .. ass_sub_data,
		('av://lavfi:color=color=black:size=%dx%d:duration=1'):format(self.IMAGE_WIDTH, target_height),
		'--frames=1',

		-- Byte for each pixel
		'--vf-add=format=gray',
		'--of=rawvideo',
		'--ovc=rawvideo',

		-- Write to stdout
		'-o=-'
	}

	local ret = utils.subprocess({args=mpv_args, cancellable=false})
	return ret.stdout
end


function TextMeasurer:get_bounds(image_data, offset)
	local w = self.IMAGE_WIDTH
	local h = self.LINE_HEIGHT

	local left_edge = nil
	local right_edge = nil

	-- Approach from left
	for x = 0, w-1 do
		for y = 0, h-1 do
			local p = image_data:byte(x + y*w + 1 + offset)
			if p > 0 then
				left_edge = x
				break
			end
		end
		if left_edge then break end
	end

	-- Approach from right
	for x = w-1, 0, -1 do
		for y = 0, h-1 do
			local p = image_data:byte(x + y*w + 1 + offset)
			if p > 0 then
				right_edge = x
				break
			end
		end
		if right_edge then break end
	end

	if left_edge and right_edge then
		return left_edge, right_edge
	end
end


function TextMeasurer:parse_characters(image_data)
	local sub_image_size = self.IMAGE_WIDTH * self.LINE_HEIGHT

	if #image_data < self.IMAGE_WIDTH * self.TOTAL_HEIGHT then
		-- Not enough bytes for all rows
		return nil
	end

	local edge_map = {}

	for i, character in ipairs(self.CHARACTERS) do
		local left, right = self:get_bounds(image_data, (i-1) * sub_image_size)
		edge_map[character] = {left, right}
	end

	local em_bound = edge_map['']
	local em_space_em_bound = edge_map['M ']

	local em_w = (em_bound[2] - em_bound[1]) + (em_bound[1] - self.BASE_X)

	-- Remove measurement characters from map
	edge_map[''] = nil
	edge_map['M '] = nil

	for character, edges in pairs(edge_map) do
		edge_map[character] = (edges[2] - self.BASE_X - em_w)
	end

	-- Space
	edge_map[' '] = (em_space_em_bound[2] - em_space_em_bound[1]) - (em_w * 2)

	return edge_map
end


function TextMeasurer:create_character_map()
	if not self.WIDTH_MAP then
		local ass_sub_data = TextMeasurer:create_ass_track()
		local image_data = TextMeasurer:render_ass_track(ass_sub_data)
		self.WIDTH_MAP = TextMeasurer:parse_characters(image_data)
		if not self.WIDTH_MAP then
			msg.error("Failed to parse character widths!")
		end
	end
	return self.WIDTH_MAP
end

-- String functions

function TextMeasurer:_utf8_iter(text)
	iter = text:gmatch('([%z\1-\127\194-\244][\128-\191]*)')
	return function() return iter() end
end

function TextMeasurer:calculate_width(text, font_size)
	local total_width = 0
	local width_map = self:create_character_map()
	local default_width = width_map['M']

	for char in self:_utf8_iter(text) do
		local char_width = width_map[char] or default_width
		total_width = total_width + char_width
	end

	return total_width * (font_size / self.FONT_HEIGHT)
end

function TextMeasurer:trim_to_width(text, font_size, max_width, suffix)
	suffix = suffix or "..."
	max_width = max_width * (self.FONT_HEIGHT / font_size) - self:calculate_width(suffix, font_size)

	local width_map = self:create_character_map()
	local default_width = width_map['M']

	local total_width = 0
	local characters = {}
	for char in self:_utf8_iter(text) do
		local char_width = width_map[char] or default_width
		total_width = total_width + char_width

		if total_width > max_width then break end
		table.insert(characters, char)
	end

	if total_width > max_width then
		return table.concat(characters, '') .. suffix
	else
		return text
	end
end

function TextMeasurer:wrap_to_width(text, font_size, max_width)
	local lines = {}
	local line_widths = {}

	local current_line = ''
	local current_width = 0

	for word in text:gmatch("( *[%S]*\n?)") do
		if word ~= '' then
			local is_newline = word:sub(-1) == '\n'
			word = word:gsub('%s*$', '')

			if word ~= '' then
				local part_width = TextMeasurer:calculate_width(word, font_size)

				if (current_width + part_width) > max_width then
					table.insert(lines, current_line)
					table.insert(line_widths, current_width)
					current_line = word:gsub('^%s*', '')
					current_width = part_width
				else
					current_line = current_line .. word
					current_width = current_width + part_width
				end
			end

			if is_newline then
				table.insert(lines, current_line)
				table.insert(line_widths, current_width)
				current_line = ''
				current_width = 0
			end
		end
	end
	table.insert(lines, current_line)
	table.insert(line_widths, current_width)

	return lines, line_widths
end


function TextMeasurer:load_or_create(file_path)
	local cache_file = io.open(file_path, 'r')
	if cache_file then
		local map_json = cache_file:read('*a')
		local width_map = utils.parse_json(map_json)
		self.WIDTH_MAP = width_map
		cache_file:close()
	else
		cache_file = io.open(file_path, 'w')
		msg.warn("Generating OSD font character measurements, this may take a second...")
		local width_map = self:create_character_map()
		local map_json = utils.format_json(width_map)
		cache_file:write(map_json)
		cache_file:close()
		msg.info("Text measurements created and saved to", file_path)
	end
end
