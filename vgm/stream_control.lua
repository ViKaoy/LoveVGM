-- hq mode enables two improvements:
-- 1. catmull-rom cubic interpolation between source samples during upsampling
-- (22050hz → 44100hz) - this eliminates the staircase/sample-hold
-- artefact that is the main cause of harshness in PWM audio;

-- 2. tpdf dithering on the final 16bit output conversion - triangular
-- probability density function dither decorrelates quantisation noise from
-- the signal, turning it from audible distortion into innocuous low-level
-- hiss below the noise floor

local bit = require("bit")
local ffi = require("ffi")

local CHIP_ENTRY_BYTES = {
	[0x11] = 2,
}

local DEFAULT_CHIP_TYPE   = 0x11
local DEFAULT_BANK_ID     = 0x03
local FALLBACK_BANK_IDS   = { 0x03, 0x11 }

local SAMPLE_RATE     = 44100
local DC_ALPHA        = 0.9995
local WAVE_SIZE       = 256

local DITHER_AMP = 1 / 32768

local function decompress_bitpack(cptr, data_len, bd, bc, st, aa, num_values)
	local out      = ffi.new("uint8_t[?]", num_values * 2)
	local data_pos = 0
	local in_shift = 0
	local max_val  = 2 ^ bd - 1

	for i = 0, num_values - 1 do
		local in_val    = 0
		local out_bit   = 0
		local bits_left = bc

		while bits_left > 0 do
			local take  = bits_left >= 8 and 8 or bits_left
			bits_left   = bits_left - take
			local mask  = bit.lshift(1, take) - 1

			in_shift    = in_shift + take
			local b0    = data_pos < data_len and cptr[data_pos] or 0
			local chunk = bit.band(bit.rshift(bit.lshift(b0, in_shift), 8), mask)

			if in_shift >= 8 then
				in_shift  = in_shift - 8
				data_pos  = data_pos + 1
				if in_shift > 0 then
					local b1 = data_pos < data_len and cptr[data_pos] or 0
					chunk = bit.bor(chunk, bit.band(bit.rshift(bit.lshift(b1, in_shift), 8), mask))
				end
			end

			in_val  = bit.bor(in_val, bit.lshift(chunk, out_bit))
			out_bit = out_bit + take
		end

		if st == 0x01 then
			in_val = in_val * (2 ^ (bd - bc))
		end

		in_val = in_val + aa
		if in_val > max_val then in_val = max_val end
		if in_val < 0       then in_val = 0       end

		local iv       = math.floor(in_val)
		out[i * 2]     = bit.band(iv, 0xFF)
		out[i * 2 + 1] = bit.band(bit.rshift(iv, 8), 0xFF)
	end
	return ffi.string(out, num_values * 2)
end

local BANK_INITIAL_CAP = 8192

local function bank_new(initial_cap)
	initial_cap = initial_cap or BANK_INITIAL_CAP
	return {
		ptr    = ffi.new("uint8_t[?]", initial_cap),
		size   = 0,
		cap    = initial_cap,
		blocks = {},
	}
end

local function bank_append(bank, src, len)
	if len <= 0 then return end
	if bank.size + len > bank.cap then
		local new_cap = math.max(bank.cap * 2, bank.size + len)
		local new_ptr = ffi.new("uint8_t[?]", new_cap)
		if bank.size > 0 then
			ffi.copy(new_ptr, bank.ptr, bank.size)
		end
		bank.ptr = new_ptr
		bank.cap = new_cap
	end
	ffi.copy(bank.ptr + bank.size, src, len)
	bank.size = bank.size + len
end

local StreamControl = {}
StreamControl.__index = StreamControl

function StreamControl.new(pwm, opts)
	local self = setmetatable({}, StreamControl)
	self.pwm             = pwm
	self.hq              = opts and opts.hq or false
	self.data_banks      = {}
	self.data_block_list = {}
	self.dac_streams     = {}

	self._xL = 0;  self._yL = 0
	self._xR = 0;  self._yR = 0

	-- waveform ring buffers for L  and R PWM output
	self.wave_l      = {}
	self.wave_r      = {}
	self.wave_pos    = 0
	self.wave_bufs   = {}
	self.wave_labels = { "L", "R" }
	for i = 1, WAVE_SIZE do self.wave_l[i] = 0; self.wave_r[i] = 0 end
	self.wave_bufs[1] = self.wave_l
	self.wave_bufs[2] = self.wave_r

	return self
end

function StreamControl:data_block(block_type, data_ptr, size)
	local store_type = block_type
	local src_ptr  = data_ptr
	local src_str  = nil
	local src_size = size

	if block_type >= 0x40 and block_type <= 0x7E and size >= 10 then
		local tt       = data_ptr[0]
		local unc_size = data_ptr[1]
			+ data_ptr[2] * 0x100
			+ data_ptr[3] * 0x10000
			+ data_ptr[4] * 0x1000000

		if tt == 0x00 then
			local bd         = data_ptr[5]
			local bc         = data_ptr[6]
			local st         = data_ptr[7]
			local aa         = data_ptr[8] + data_ptr[9] * 0x100
			local byte_width = math.ceil(bd / 8)
			local num_values = math.floor(unc_size / byte_width)

			local ok, result = pcall(
				decompress_bitpack,
				data_ptr + 10, size - 10,
				bd, bc, st, aa, num_values)
			if ok then
				src_ptr    = nil
				src_str    = result
				src_size   = #result
				store_type = block_type - 0x40
			else
				print(string.format(
					"[stream_control] warn: decompression failed for block 0x%02X: %s",
					block_type, tostring(result)))
			end
		else
			print(string.format(
				"[stream_control] warn: unsupported compression type %d for block 0x%02X — using raw",
				tt, block_type))
		end
	end

	if store_type == 0x7F then return end

	if not self.data_banks[store_type] then
		self.data_banks[store_type] = bank_new(math.max(src_size, BANK_INITIAL_CAP))
	end

	local bank         = self.data_banks[store_type]
	local block_offset = bank.size

	if src_ptr then
		bank_append(bank, src_ptr, src_size)
	else
		bank_append(bank, src_str, src_size)
	end

	local entry = { bank_id = store_type, offset = block_offset, size = src_size }
	bank.blocks[#bank.blocks + 1]                   = entry
	self.data_block_list[#self.data_block_list + 1] = entry
end

function StreamControl:write_chip(reg, val)
	if reg == 0x02 or reg == 0x03 then
		for _, s in pairs(self.dac_streams) do
			if s.active and s.cmd_byte == reg then return end
		end
	end
	self.pwm:write(reg, val)
end

function StreamControl:setup_chip(sid, chip_type, port, command)
	local s             = self:_get_stream(sid)
	s.chip_type         = chip_type
	s.port              = port
	s.cmd_byte          = command
	s.step_size_bytes   = self:_entry_bytes(chip_type)
end

function StreamControl:setup_data(sid, bank_id, step_size, step_base)
	local s             = self:_get_stream(sid)
	local eb            = self:_entry_bytes(s.chip_type)
	s.bank_id           = bank_id
	s.step_size_bytes   = step_size * eb
	s.step_base_bytes   = step_base * eb
end

function StreamControl:setup_freq(sid, frequency)
	local s     = self:_get_stream(sid)
	s.frequency = frequency > 0 and frequency or 22050
end

function StreamControl:start_stream(sid, data_start, length_mode, data_length)
	local s    = self:_get_stream(sid)
	local bank = self.data_banks[s.bank_id]

	if not bank then
		for _, fid in ipairs(FALLBACK_BANK_IDS) do
			if self.data_banks[fid] then
				bank      = self.data_banks[fid]
				s.bank_id = fid
				print(string.format(
					"[stream_control] warn: bank %d not found for stream %d, using fallback %d",
					s.bank_id, sid, fid))
				break
			end
		end
		if not bank then
			print(string.format(
				"[stream_control] warn: bank %d missing — stream %d not started",
				s.bank_id, sid))
			return
		end
	end

	local bank_size = bank.size
	local do_loop   = bit.band(length_mode, 0x80) ~= 0
	local mode      = bit.band(length_mode, 0x7F)

	local start_bytes
	if data_start == 0xFFFFFFFF then
		start_bytes = s.pos
	else
		start_bytes = data_start + s.step_base_bytes
	end
	start_bytes = math.max(0, math.min(start_bytes, bank_size))

	local end_bytes
	if mode == 0x00 then
		s.pos = start_bytes; return
	elseif mode == 0x01 then
		end_bytes = start_bytes + data_length * s.step_size_bytes
	elseif mode == 0x02 then
		local n   = math.floor(data_length * s.frequency / 1000)
		end_bytes = start_bytes + n * s.step_size_bytes
	else
		end_bytes = bank_size
	end
	end_bytes = math.min(end_bytes, bank_size)

	s.start_pos = start_bytes
	s.end_pos   = end_bytes
	s.pos       = start_bytes
	s.frac      = 0
	s.loop      = do_loop
	s.active    = true

	if self.hq then
		local v = self:_read_sample_norm(s, start_bytes)
		s.h[0] = v; s.h[1] = v; s.h[2] = v; s.h[3] = v
	end
end

function StreamControl:stop_stream(sid)
	if sid == 0xFF then
		for _, s in pairs(self.dac_streams) do s.active = false end
	else
		local s = self.dac_streams[sid]
		if s then s.active = false end
	end
end

function StreamControl:start_fast(sid, block_id, flags)
	local entry = self.data_block_list[block_id + 1]
	if not entry then
		print(string.format(
			"[stream_control] warn: unknown block id %d for stream %d", block_id, sid))
		return
	end
	local s     = self:_get_stream(sid)
	s.bank_id   = entry.bank_id
	s.start_pos = entry.offset
	s.end_pos   = entry.offset + entry.size
	s.pos       = entry.offset
	s.frac      = 0
	s.loop      = bit.band(flags, 0x01) ~= 0
	s.active    = true

	if self.hq then
		local v = self:_read_sample_norm(s, s.start_pos)
		s.h[0] = v; s.h[1] = v; s.h[2] = v; s.h[3] = v
	end
end

function StreamControl:_get_stream(sid)
	if not self.dac_streams[sid] then
		self.dac_streams[sid] = {
			chip_type = DEFAULT_CHIP_TYPE,
			bank_id   = DEFAULT_BANK_ID,
			port            = 0,
			cmd_byte        = 0,
			step_size_bytes = PWM_ENTRY_BYTES,
			step_base_bytes = 0,
			frequency       = 22050,
			active          = false,
			loop            = false,
			start_pos       = 0,
			end_pos         = 0,
			pos             = 0,
			frac            = 0,
			h               = {0, 0, 0, 0},
		}
	end
	return self.dac_streams[sid]
end

function StreamControl:_entry_bytes(chip_type)
	return CHIP_ENTRY_BYTES[chip_type] or 1
end

function StreamControl:any_active()
	for _, s in pairs(self.dac_streams) do
		if s.active then return true end
	end
	return false
end

function StreamControl:_read_sample_norm(s, pos)
	local bank = self.data_banks[s.bank_id]
	if not bank or pos + 2 > bank.size then return 0 end
	local lo  = bank.ptr[pos]
	local hi  = bank.ptr[pos + 1]
	local raw = lo + bit.lshift(bit.band(hi, 0x0F), 8)
	local center = self.pwm.offset > 0 and self.pwm.offset or 520
	local v = (raw - center) / center
	if v >  1 then return  1 end
	if v < -1 then return -1 end
	return v
end

function StreamControl:_tick_stream(s)
	s.frac = s.frac + (s.frequency / SAMPLE_RATE)

	while s.frac >= 1 do
		local bank = self.data_banks[s.bank_id]
		if not bank then s.active = false; break end

		if s.pos + 2 > bank.size then
			if s.loop then s.pos = s.start_pos
			else s.active = false; break end
		end

		local lo  = bank.ptr[s.pos]
		local hi  = bank.ptr[s.pos + 1]
		local val = lo + bit.lshift(bit.band(hi, 0x0F), 8)
		self.pwm:write(s.cmd_byte, val)

		s.pos  = s.pos + s.step_size_bytes
		s.frac = s.frac - 1

		if s.pos >= s.end_pos then
			if s.loop then s.pos = s.start_pos else s.active = false; break end
		end
	end
end

function StreamControl:_tick_stream_hq(s)
	s.frac = s.frac + (s.frequency / SAMPLE_RATE)

	while s.frac >= 1 do
		local bank = self.data_banks[s.bank_id]
		if not bank then s.active = false; return 0 end

		if s.pos + 2 > bank.size then
			if s.loop then s.pos = s.start_pos
			else s.active = false; return 0 end
		end

		local h    = s.h
		h[0] = h[1]; h[1] = h[2]; h[2] = h[3]
		h[3] = self:_read_sample_norm(s, s.pos)

		s.pos  = s.pos + s.step_size_bytes
		s.frac = s.frac - 1

		if s.pos >= s.end_pos then
			if s.loop then s.pos = s.start_pos else s.active = false end
		end
	end

	-- catmull-rom spline between h[1] and h[2] at t = s.frac belto [0, 1)
	local h  = s.h
	local p0, p1, p2, p3 = h[0], h[1], h[2], h[3]
	local t  = s.frac
	local t2 = t * t
	local t3 = t2 * t
	local v  = 0.5 * (
		  2 * p1
		+ (-p0 + p2)                * t
		+ (2*p0 - 5*p1 + 4*p2 - p3) * t2
		+ (-p0 + 3*p1 - 3*p2 + p3)  * t3
	)
	if v >  1 then return  1 end
	if v < -1 then return -1 end
	return v
end

function StreamControl:render(buf, off, n)
	off = off or 0

	if not self.hq then
		for i = 0, n - 1 do
			for _, s in pairs(self.dac_streams) do
				if s.active then self:_tick_stream(s) end
			end

			local L, R = self.pwm:step()

			local yL = L - self._xL + DC_ALPHA * self._yL
			local yR = R - self._xR + DC_ALPHA * self._yR
			self._xL = L;  self._yL = yL
			self._xR = R;  self._yR = yR
			if yL >  1 then yL =  1 elseif yL < -1 then yL = -1 end
			if yR >  1 then yR =  1 elseif yR < -1 then yR = -1 end

			local li    = (off + i) * 2
			buf[li]     = math.floor(yL * 32767)
			buf[li + 1] = math.floor(yR * 32767)
		end
		return
	end

	for i = 0, n - 1 do
		local L_acc = 0
		local R_acc = 0
		local has_stream = false

		for _, s in pairs(self.dac_streams) do
			if s.active then
				local v = self:_tick_stream_hq(s)
				if s.cmd_byte == 0x02 then
					L_acc = L_acc + v
					has_stream = true
				elseif s.cmd_byte == 0x03 then
					R_acc = R_acc + v
					has_stream = true
				else
					self.pwm:write(s.cmd_byte, math.floor(
						v * self.pwm.offset + self.pwm.offset))
				end
			end
		end

		local L, R
		if has_stream then
			L = L_acc
			R = R_acc
		else
			L, R = self.pwm:step()
		end

		local yL = L - self._xL + DC_ALPHA * self._yL
		local yR = R - self._xR + DC_ALPHA * self._yR
		self._xL = L;  self._yL = yL
		self._xR = R;  self._yR = yR
		if yL >  1 then yL =  1 elseif yL < -1 then yL = -1 end
		if yR >  1 then yR =  1 elseif yR < -1 then yR = -1 end

		local dL = (math.random() - math.random()) * DITHER_AMP
		local dR = (math.random() - math.random()) * DITHER_AMP

		local li = (off + i) * 2
		local sL = math.floor((yL + dL) * 32767)
		local sR = math.floor((yR + dR) * 32767)
		if sL >  32767 then sL =  32767 elseif sL < -32768 then sL = -32768 end
		if sR >  32767 then sR =  32767 elseif sR < -32768 then sR = -32768 end
		buf[li]     = sL
		buf[li + 1] = sR

		local wp = self.wave_pos % WAVE_SIZE + 1
		self.wave_l[wp] = yL
		self.wave_r[wp] = yR
		self.wave_pos = wp
	end
end

return StreamControl
