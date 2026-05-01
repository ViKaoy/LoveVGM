-- parses VGM file headers and exposes raw byte access
-- supports VGM versions 1.00~1.71 (i hope)

local ffi = require("ffi")

local VGM_MAGIC = "Vgm "
local VGM_VERSION_MIN = 0x100

local Parser = {}
Parser.__index = Parser

function Parser.new(data)
	assert(type(data) == "string", "Parser.new: expected string data")
	assert(#data >= 0x40,          "Parser.new: file too small to be a VGM")

	local self = setmetatable({}, Parser)
	self._data_ref = data
	self.ptr       = ffi.cast("const uint8_t*", data)
	self.size      = #data
	self.pos       = 0
	return self
end

function Parser:seek(pos)
	assert(pos >= 0 and pos <= self.size, string.format(
		"Parser:seek out of range: %d (size %d)", pos, self.size))
	self.pos = pos
end

function Parser:tell() return self.pos end

function Parser:eof() return self.pos >= self.size end

function Parser:read_u8()
	assert(self.pos < self.size, "Parser:read_u8 past EOF")
	local v = self.ptr[self.pos]
	self.pos = self.pos + 1
	return v
end

function Parser:read_u16_le()
	assert(self.pos + 1 < self.size, "Parser:read_u16_le past EOF")
	local lo = self.ptr[self.pos]
	local hi = self.ptr[self.pos + 1]
	self.pos = self.pos + 2
	return lo + hi * 0x100
end

function Parser:read_u32_le()
	assert(self.pos + 3 < self.size, "Parser:read_u32_le past EOF")
	local b0 = self.ptr[self.pos]
	local b1 = self.ptr[self.pos + 1]
	local b2 = self.ptr[self.pos + 2]
	local b3 = self.ptr[self.pos + 3]
	self.pos = self.pos + 4
	return b0 + b1 * 0x100 + b2 * 0x10000 + b3 * 0x1000000
end

function Parser:read_relative_offset(field_pos)
	self:seek(field_pos)
	local raw = self:read_u32_le()
	if raw == 0 then return 0 end
	return field_pos + raw
end

function Parser:peek_u8()
	assert(self.pos < self.size, "Parser:peek_u8 past EOF")
	return self.ptr[self.pos]
end

function Parser:parse_header()
	local magic = string.char(
		self.ptr[0], self.ptr[1], self.ptr[2], self.ptr[3])
	assert(magic == VGM_MAGIC,
		string.format("Not a VGM file (magic = %q)", magic))
	self:seek(0x04)
	local eof_rel  = self:read_u32_le()
	local eof_abs  = 0x04 + eof_rel

	local version = self:read_u32_le()
	assert(version >= VGM_VERSION_MIN,
		string.format("Unsupported VGM version: 0x%08X", version))

	local hdr = {
		version     = version,
		version_str = string.format("%d.%02X", math.floor(version / 0x100), version % 0x100),
		eof_offset  = eof_abs,
	}

	hdr.sn76489_clock = self:read_u32_le()
	hdr.ym2413_clock  = self:read_u32_le()
	hdr.gd3_offset    = self:read_relative_offset(0x14)

	self:seek(0x18)
	hdr.total_samples = self:read_u32_le()
	hdr.loop_offset   = self:read_relative_offset(0x1C)

	self:seek(0x20)
	hdr.loop_samples  = self:read_u32_le()

	hdr.rate = 0
	if version >= 0x101 then
		self:seek(0x24)
		hdr.rate = self:read_u32_le()
	end

	hdr.sn76489_feedback    = 0
	hdr.sn76489_shift_width = 16
	hdr.sn76489_flags       = 0
	if version >= 0x110 then
		self:seek(0x28)
		hdr.sn76489_feedback    = self:read_u16_le()
		hdr.sn76489_shift_width = self:read_u8()
		hdr.sn76489_flags       = self:read_u8()
	end

	hdr.ym2612_clock = 0
	hdr.ym2151_clock = 0
	if version >= 0x110 then
		self:seek(0x2C)
		hdr.ym2612_clock = self:read_u32_le()
		hdr.ym2151_clock = self:read_u32_le()
	end

	if version >= 0x150 then
		hdr.data_offset = self:read_relative_offset(0x34)
		if hdr.data_offset == 0 then
			hdr.data_offset = 0x40
		end
	else
		hdr.data_offset = 0x40
	end

	hdr.sega_pcm_clock      = 0
	hdr.rf5c68_clock        = 0
	hdr.ym2203_clock        = 0
	hdr.ym2608_clock        = 0
	hdr.ym2610_clock        = 0
	hdr.ym3812_clock        = 0
	hdr.ym3526_clock        = 0
	hdr.y8950_clock         = 0
	hdr.ymf262_clock        = 0
	hdr.ymf278b_clock       = 0
	hdr.ymf271_clock        = 0
	hdr.ymz280b_clock       = 0
	hdr.rf5c164_clock       = 0
	hdr.pwm_clock           = 0
	hdr.ay8910_clock        = 0

	if version >= 0x151 and hdr.data_offset > 0x40 then
		self:seek(0x38)
		hdr.sega_pcm_clock = self:read_u32_le()
		self:seek(0x40)
		hdr.rf5c68_clock   = self:read_u32_le()
		hdr.ym2203_clock   = self:read_u32_le()
		hdr.ym2608_clock   = self:read_u32_le()
		hdr.ym2610_clock   = self:read_u32_le()
		hdr.ym3812_clock   = self:read_u32_le()
		hdr.ym3526_clock   = self:read_u32_le()
		hdr.y8950_clock    = self:read_u32_le()
		hdr.ymf262_clock   = self:read_u32_le()
		hdr.ymf278b_clock  = self:read_u32_le()
		hdr.ymf271_clock   = self:read_u32_le()
		hdr.ymz280b_clock  = self:read_u32_le()
		hdr.rf5c164_clock  = self:read_u32_le()
		hdr.pwm_clock      = self:read_u32_le()
		hdr.ay8910_clock   = self:read_u32_le()
	end

	hdr.duration_sec = hdr.total_samples / 44100
	self:seek(hdr.data_offset)

	return hdr
end

local function read_utf16le_string(ptr, pos, max_pos)
	local chars = {}
	while pos + 1 < max_pos do
		local lo = ptr[pos]
		local hi = ptr[pos + 1]
		pos = pos + 2
		if lo == 0 and hi == 0 then break end
		if lo ~= 0 then
			chars[#chars + 1] = string.char(lo)
		end
	end
	return table.concat(chars), pos
end

function Parser:parse_gd3(hdr)
	if not hdr.gd3_offset or hdr.gd3_offset == 0 then
		return nil
	end

	self:seek(hdr.gd3_offset)
	local magic = string.char(
		self.ptr[hdr.gd3_offset],
		self.ptr[hdr.gd3_offset + 1],
		self.ptr[hdr.gd3_offset + 2],
		self.ptr[hdr.gd3_offset + 3])
	if magic ~= "Gd3 " then return nil end

	self:seek(hdr.gd3_offset + 4)
	local gd3_version = self:read_u32_le()  --  should be 0x100 ?
	local data_len    = self:read_u32_le()
	local data_start  = self:seek(hdr.gd3_offset + 12) or (hdr.gd3_offset + 12)

	local pos = hdr.gd3_offset + 12
	local limit = pos + data_len
	local fields = {"track_en",  "track_jp",  "game_en",   "game_jp",
					"system_en", "system_jp", "author_en", "author_jp",
					"date",      "ripper",    "notes"
	}
	local gd3 = {}
	for _, field in ipairs(fields) do
		local s
		s, pos = read_utf16le_string(self.ptr, pos, limit)
		gd3[field] = s
	end

	gd3.track  = gd3.track_en  ~= "" and gd3.track_en  or gd3.track_jp
	gd3.game   = gd3.game_en   ~= "" and gd3.game_en   or gd3.game_jp
	gd3.system = gd3.system_en ~= "" and gd3.system_en or gd3.system_jp
	gd3.author = gd3.author_en ~= "" and gd3.author_en or gd3.author_jp

	return gd3
end

return Parser
