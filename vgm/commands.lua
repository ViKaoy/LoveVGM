local Commands = {}
Commands.__index = Commands

local bit = require("bit")

local CHIP_WRITE = {
	[0x4F] = { "psg_gg_stereo", 1 },
	[0x50] = { "sn76489",       1 },
	[0x51] = { "ym2413",        2 },
	[0x52] = { "ym2612_p0",     2 },
	[0x53] = { "ym2612_p1",     2 },
	[0x54] = { "ym2151",        2 },
	[0x55] = { "ym2203",        2 },
	[0x56] = { "ym2608_p0",     2 },
	[0x57] = { "ym2608_p1",     2 },
	[0x58] = { "ym2610_p0",     2 },
	[0x59] = { "ym2610_p1",     2 },
	[0x5A] = { "ym3812",        2 },
	[0x5B] = { "ym3526",        2 },
	[0x5C] = { "y8950",         2 },
	[0x5D] = { "ymz280b",       2 },
	[0x5E] = { "ymf262_p0",     2 },
	[0x5F] = { "ymf262_p1",     2 },
	[0xA0] = { "ay8910",        2 },
}

for b = 0xB0, 0xBF do
	CHIP_WRITE[b] = { string.format("chip_b%02X", b), 2 }
end
CHIP_WRITE[0xB2] = { "pwm32x",   2 }
CHIP_WRITE[0xB1] = { "rf5c164",  2 }
CHIP_WRITE[0xB0] = { "rf5c68",   2 }

local TWO_ADDR = {}
for b = 0xC0, 0xC8 do TWO_ADDR[b] = true end
for b = 0xD0, 0xD6 do TWO_ADDR[b] = true end

function Commands.new(parser, header, cbs)
	local self = setmetatable({}, Commands)
	self.parser      = parser
	self.header      = header
	self.cbs         = cbs or {}
	self.done        = false
	self.loop_offset = header.loop_offset
	self.looping     = true
	self.samples_waited = 0

	local limit = header.eof_offset
	if header.gd3_offset and header.gd3_offset ~= 0 then
		limit = math.min(limit, header.gd3_offset)
	end
	self.data_end = limit

	return self
end

local function call(cbs, name, ...)
	local fn = cbs[name]
	if fn then fn(...) end
end

function Commands:_read_data_block()
	local p = self.parser
	local compat     = p:read_u8()
	local block_type = p:read_u8()
	local size       = bit.band(p:read_u32_le(), 0x7FFFFFFF)
	local data_ptr   = p.ptr + p:tell()
	p:seek(p:tell() + size)
	call(self.cbs, "on_data_block", block_type, data_ptr, size)
end

function Commands:_read_pcm_ram_write()
	local p = self.parser
	p:read_u8()
	local chip_type = p:read_u8()
	local read_off  = p:read_u8() + p:read_u16_le() * 0x100
	local write_off = p:read_u8() + p:read_u16_le() * 0x100
	local size      = p:read_u8() + p:read_u16_le() * 0x100
	read_off  = read_off  % 0x1000000
	write_off = write_off % 0x1000000
	size      = size      % 0x1000000
	call(self.cbs, "on_pcm_ram_write", chip_type, read_off, write_off, size)
end

function Commands:step()
	if self.done then return false end

	local p   = self.parser
	local cbs = self.cbs

	if p:tell() >= self.data_end or p:eof() then
		self.done = true
		call(cbs, "on_end")
		return false
	end

	local cmd = p:read_u8()

	if cmd == 0x67 then
		self:_read_data_block()
		return true
	end

	if cmd == 0x68 then
		self:_read_pcm_ram_write()
		return true
	end

	if cmd == 0x66 then
		if self.loop_offset ~= 0 and self.looping then
			p:seek(self.loop_offset)
			call(cbs, "on_loop")
			return true
		else
			self.done = true
			call(cbs, "on_end")
			return false
		end
	end

	if cmd >= 0x70 and cmd <= 0x7F then
		local n = bit.band(cmd, 0x0F) + 1
		self.samples_waited = self.samples_waited + n
		call(cbs, "on_wait", n)
		return true
	end

	if cmd >= 0x80 and cmd <= 0x8F then
		local wait_n = bit.band(cmd, 0x0F)
		call(cbs, "on_dac_bank_write", wait_n)
		return true
	end

	if cmd == 0x61 then
		local n = p:read_u16_le()
		self.samples_waited = self.samples_waited + n
		call(cbs, "on_wait", n)
		return true
	end

	if cmd == 0x62 then
		self.samples_waited = self.samples_waited + 735
		call(cbs, "on_wait", 735)
		return true
	end

	if cmd == 0x63 then
		self.samples_waited = self.samples_waited + 882
		call(cbs, "on_wait", 882)
		return true
	end

	if cmd == 0x64 then
		local override_cmd = p:read_u8()
		local n = p:read_u16_le()
		self.samples_waited = self.samples_waited + n
		call(cbs, "on_wait", n)
		return true
	end

	if cmd == 0xE0 then
		local offset = p:read_u32_le()
		call(cbs, "on_seek", offset)
		return true
	end

	local chip_info = CHIP_WRITE[cmd]
	if chip_info then
		local chip_name, n_bytes = chip_info[1], chip_info[2]
		if n_bytes == 1 then
			local val = p:read_u8()
			call(cbs, "on_chip_write", chip_name, 0x00, val)
		else
			local reg = p:read_u8()
			local val = p:read_u8()
			if chip_name == "ym2612_p0" and reg == 0x2A then
				call(cbs, "on_dac_write", val)
			end
			call(cbs, "on_chip_write", chip_name, reg, val)
		end
		return true
	end

	if TWO_ADDR[cmd] then
		local addr_lo = p:read_u8()
		local addr_hi = p:read_u8()
		local val     = p:read_u8()
		local addr    = addr_lo + addr_hi * 0x100
		call(cbs, "on_chip_write",
			string.format("chip_%02X", cmd), addr, val)
		return true
	end

	if cmd == 0x90 then
		local sid     = p:read_u8()
		local chip_t  = p:read_u8()
		local port    = p:read_u8()
		local command = p:read_u8()
		call(cbs, "on_dac_setup_chip", sid, chip_t, port, command)
		return true
	end
	if cmd == 0x91 then
		local sid       = p:read_u8()
		local bank_id   = p:read_u8()
		local step_size = p:read_u8()
		local step_base = p:read_u8()
		call(cbs, "on_dac_setup_data", sid, bank_id, step_size, step_base)
		return true
	end
	if cmd == 0x92 then
		local sid  = p:read_u8()
		local freq = p:read_u32_le()
		call(cbs, "on_dac_setup_freq", sid, freq)
		return true
	end
	if cmd == 0x93 then
		local sid         = p:read_u8()
		local data_start  = p:read_u32_le()
		local length_mode = p:read_u8()
		local data_length = p:read_u32_le()
		call(cbs, "on_dac_start", sid, data_start, length_mode, data_length)
		return true
	end
	if cmd == 0x94 then
		local sid = p:read_u8()
		call(cbs, "on_dac_stop", sid)
		return true
	end
	if cmd == 0x95 then
		local sid      = p:read_u8()
		local block_id = p:read_u16_le()
		local flags    = p:read_u8()
		call(cbs, "on_dac_start_fast", sid, block_id, flags)
		return true
	end

	if cmd == 0x65 then return true end

	print(string.format("[vgm/commands] Unknown command 0x%02X at file offset 0x%X — stopping.", cmd, p:tell() - 1))
	self.done = true
	call(cbs, "on_end")
	return false
end

function Commands:run(n)
	local consumed = 0
	local target   = n

	local original_wait = self.cbs.on_wait
	local done_flag     = false

	self.cbs.on_wait = function(samples)
		consumed = consumed + samples
		if original_wait then original_wait(samples) end
		if consumed >= target then
			done_flag = true
		end
	end

	while not done_flag and not self.done do
		self:step()
	end

	self.cbs.on_wait = original_wait
	return consumed
end

return Commands
