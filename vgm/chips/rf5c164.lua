local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
        typedef uint8_t rf_u8;
]]

local WAVE_SIZE = 256

local RF5C164 = {}
RF5C164.__index = RF5C164

local DEFAULT_CLOCK  = 12500000
local OUTPUT_RATE    = 44100
local FRACT_BITS     = 11
local FRACT_SCALE    = 2048
local ADDR_MAX       = 134217728
local RAM_SIZE       = 0x10000
local LOOP_END       = 0xFF

function RF5C164.new(clock)
	local self = setmetatable({}, RF5C164)
	self.clock             = (clock and clock ~= 0) and clock or DEFAULT_CLOCK
	self.ticks_per_sample  = (self.clock / 384) / OUTPUT_RATE
	self.tick_acc          = 0
	self.out_l             = 0
	self.out_r             = 0

	self.ram               = ffi.new("rf_u8[65536]")
	ffi.fill(self.ram, 65536, 0)

	self.enabled           = false
	self.selected_channel  = 0
	self.ram_bank          = 0
	self.channel_enable    = 0xFF

	self._pcm_stream_ptr   = nil
	self._pcm_stream_len   = 0

	self.channels = {}
	for i = 0, 7 do
			self.channels[i] = {
					env       = 0,
					pan       = 0,
					step      = 0,
					loop_addr = 0,
					start_val = 0,
					addr      = 0,
			}
	end

	self.wave_bufs  = {}
	self.wave_labels = { "P1","P2","P3","P4","P5","P6","P7","P8" }
	self.wave_pos   = 0
	for i = 1, 8 do
			local t = {}
			for j = 1, WAVE_SIZE do t[j] = 0 end
			self.wave_bufs[i] = t
	end
	self.ch_out = {}
	for i = 0, 7 do self.ch_out[i] = 0 end

	return self
end

function RF5C164:set_pcm_stream(data_ptr, data_len)
        self._pcm_stream_ptr = data_ptr
        self._pcm_stream_len = data_len
end

function RF5C164:write_reg(reg, val)
	if reg == 0x07 then
		self.enabled = bit.band(val, 0x80) ~= 0
		if bit.band(val, 0x40) ~= 0 then
			self.selected_channel = bit.band(val, 0x07)
		else
			self.ram_bank = bit.lshift(bit.band(val, 0x0F), 12)
		end
		return
	end

	if reg == 0x08 then
		for i = 0, 7 do
			local mask = bit.lshift(1, i)
			if bit.band(self.channel_enable, mask) ~= 0 then
				local ch = self.channels[i]
				ch.addr  = ch.start_val * 256 * FRACT_SCALE
			end
		end
		self.channel_enable = val
		return
	end

	local ch = self.channels[self.selected_channel]
	if     reg == 0x00 then
		ch.env       = val
	elseif reg == 0x01 then
		ch.pan       = val
	elseif reg == 0x02 then
		ch.step      = bit.bor(bit.band(ch.step, 0xFF00), val)
	elseif reg == 0x03 then
		ch.step      = bit.bor(bit.band(ch.step, 0x00FF), bit.lshift(val, 8))
	elseif reg == 0x04 then
		ch.loop_addr = bit.bor(bit.band(ch.loop_addr, 0xFF00), val)
	elseif reg == 0x05 then
		ch.loop_addr = bit.bor(bit.band(ch.loop_addr, 0x00FF), bit.lshift(val, 8))
	elseif reg == 0x06 then
		ch.start_val = val
	end
end

function RF5C164:write_ram(addr, val)
	self.ram[bit.bor(self.ram_bank, bit.band(addr, 0xFFFF))] = val
end

function RF5C164:load_block(start_addr, data_ptr, data_len)
	start_addr = bit.bor(self.ram_bank, bit.band(start_addr, 0xFFFF))
	local copy_len = math.min(data_len, RAM_SIZE - start_addr)
	if copy_len > 0 then
		ffi.copy(self.ram + start_addr, data_ptr, copy_len)
	end
end

function RF5C164:copy_from_stream(read_off, write_off, size)
	if not self._pcm_stream_ptr then return end
	local available = self._pcm_stream_len - read_off
	if available <= 0 then return end
	write_off = bit.bor(self.ram_bank, bit.band(write_off, 0xFFFF))
	local copy_len = math.min(size, available, RAM_SIZE - write_off)
	if copy_len <= 0 then return end
	ffi.copy(self.ram + write_off, self._pcm_stream_ptr + read_off, copy_len)
end

function RF5C164:_clock()
	if not self.enabled then
		self.out_l = 0
		self.out_r = 0
		return
	end

	local sum_l = 0
	local sum_r = 0

	for i = 0, 7 do
		local mask = bit.lshift(1, i)
		if bit.band(self.channel_enable, mask) == 0 then
			local ch = self.channels[i]

			local addr_int = math.floor(ch.addr / FRACT_SCALE)
			local ram_addr = addr_int % RAM_SIZE
			local s = self.ram[ram_addr]

			if s == LOOP_END then
				ch.addr = ch.loop_addr * FRACT_SCALE
				ram_addr = ch.loop_addr % RAM_SIZE
				s = self.ram[ram_addr]
				if s == LOOP_END then s = 0 end
			end

			local sign  = (bit.band(s, 0x80) ~= 0) and 1 or -1
			local mag   = bit.band(s, 0x7F)
			local amp   = mag * ch.env
			local pan_l = bit.band(ch.pan, 0x0F)
			local pan_r = bit.rshift(bit.band(ch.pan, 0xF0), 4)

			sum_l = sum_l + sign * math.floor(amp * pan_l / 32)
			sum_r = sum_r + sign * math.floor(amp * pan_r / 32)

			-- mono amplitude for waveform display normalized by 127*255
			self.ch_out[i] = sign * amp / 32385

			local old_addr_int = addr_int
			ch.addr = (ch.addr + ch.step) % ADDR_MAX
		end
	end

	if sum_l >  32767 then sum_l =  32767 end
	if sum_l < -32768 then sum_l = -32768 end
	if sum_r >  32767 then sum_r =  32767 end
	if sum_r < -32768 then sum_r = -32768 end

	self.out_l = sum_l
	self.out_r = sum_r
end

function RF5C164:render(buf, off, n)
	off = off or 0
	for frame = 0, n - 1 do
		self.tick_acc = self.tick_acc + self.ticks_per_sample
		while self.tick_acc >= 1 do
				self.tick_acc = self.tick_acc - 1
				self:_clock()
		end
		local li       = (off + frame) * 2
		buf[li]        = self.out_l
		buf[li + 1]    = self.out_r

		local wp = self.wave_pos % WAVE_SIZE + 1
		for i = 0, 7 do
				self.wave_bufs[i + 1][wp] = self.ch_out[i]
		end
		self.wave_pos = wp
	end
end

RF5C164.descriptor = {
	id          = "rf5c164",
	clock_field = "rf5c164_clock",
	gain        = 0.625,
	new = function(clock, hdr)
		return RF5C164.new(clock)
	end,
	commands = {
		rf5c164 = function(chip, reg, val) chip:write_reg(reg, val) end,
		chip_C1 = function(chip, reg, val) chip:write_ram(reg, val) end,
	},
	events = {
		on_data_block = function(chip, block_type, ptr, len)
			if block_type == 0x02 then
				chip:set_pcm_stream(ptr, len)
			elseif block_type == 0xC1 then
				if len >= 2 then
					local start_addr = ptr[0] + ptr[1] * 0x100
					chip:load_block(start_addr, ptr + 2, len - 2)
				end
			end
		end,
		on_pcm_ram_write = function(chip, chip_type, read_off, write_off, size)
			if chip_type == 0x02 then
				chip:copy_from_stream(read_off, write_off, size)
			end
		end,
	},
	render = function(chip, buf, off, n)
		chip:render(buf, off, n)
	end,
	wave_extra = function(chip)
		local bit = require("bit")
		local active = {}
		for i = 0, 7 do
			active[i + 1] = bit.band(chip.channel_enable, bit.lshift(1, i)) == 0
		end
		return { active = active }
	end,
}

return RF5C164
