local bit = require("bit")
local ffi = require("ffi")

local VOL = ffi.new("uint16_t[16]", {
	32767, 26028, 20675, 16422, 13045, 10362,  8231,  6568,
	 5193,  4125,  3277,  2603,  2067,  1642,  1304,     0,
})
local NOISE_PERIOD = ffi.new("uint8_t[4]", {0x10, 0x20, 0x40, 0})

local LFSR_INIT   = 0x8000
local TAPPED_BITS = 0x0009

local WAVE_SIZE  = 256
local INV_32767  = 1 / 32767

local function parity16(v)
	v = bit.bxor(v, bit.rshift(v, 8))
	v = bit.bxor(v, bit.rshift(v, 4))
	v = bit.bxor(v, bit.rshift(v, 2))
	v = bit.bxor(v, bit.rshift(v, 1))
	return bit.band(v, 1)
end

local SN76489 = {}
SN76489.__index = SN76489

SN76489.CLOCK_NTSC = 3579545
SN76489.CLOCK_PAL  = 3546893

function SN76489.new(clock, sample_rate)
	local self = setmetatable({}, SN76489)

	self.clock = clock or SN76489.CLOCK_NTSC
	local sr = sample_rate or 44100

	self.ticks_per_sample = (self.clock / 16) / sr
	self.time_to_tick = 1

	self.tone = {
		{ period = 0, counter = 1, output = 1 },
		{ period = 0, counter = 1, output = 1 },
		{ period = 0, counter = 1, output = 1 },
	}

	self.vol = { 15, 15, 15, 15 }

	self.noise_mode    = 0
	self.noise_rate    = 0
	self.noise_period  = 0x10
	self.noise_counter = 0x10
	self.lfsr          = LFSR_INIT
	self.noise_output  = 1

	self.latch = 0

	self.wave_bufs   = { {}, {}, {}, {} }
	self.wave_labels = { "T1", "T2", "T3", "Ns" }
	self.wave_pos    = 0
	for ch = 1, 4 do
		for i = 1, WAVE_SIZE do self.wave_bufs[ch][i] = 0 end
	end

	return self
end

function SN76489:write(val)
	val = bit.band(val, 0xFF)

	if bit.band(val, 0x80) ~= 0 then
		local ch  = bit.band(bit.rshift(val, 5), 0x03)
		local typ = bit.band(bit.rshift(val, 4), 0x01)
		local data = bit.band(val, 0x0F)

		self.latch = ch * 2 + typ

		if typ == 1 then
			self.vol[ch + 1] = data
		elseif ch < 3 then
			local t = self.tone[ch + 1]
			t.period = bit.bor(bit.band(t.period, 0x3F0), data)
			if ch == 2 and self.noise_rate == 3 then
				local p = t.period
				self.noise_period = (p < 1) and 1 or p
			end
		else
			self:_write_noise(data)
		end

	else
		local ch  = bit.rshift(self.latch, 1)
		local typ = bit.band(self.latch, 1)

		if typ == 1 then
			self.vol[ch + 1] = bit.band(val, 0x0F)
		elseif ch < 3 then
			local t   = self.tone[ch + 1]
			local hi6 = bit.band(val, 0x3F)
			t.period = bit.bor(bit.lshift(hi6, 4), bit.band(t.period, 0x0F))
			if ch == 2 and self.noise_rate == 3 then
				local p = t.period
				self.noise_period = (p < 1) and 1 or p
			end
		else
			self:_write_noise(bit.band(val, 0x07))
		end
	end
end

function SN76489:_write_noise(data)
	self.noise_mode = bit.band(bit.rshift(data, 2), 1)
	self.noise_rate = bit.band(data, 0x03)

	self.lfsr = LFSR_INIT

	if self.noise_rate == 3 then
		self.noise_period = (self.tone[3].period < 1) and 1 or self.tone[3].period
	else
		self.noise_period = NOISE_PERIOD[self.noise_rate]
	end
	self.noise_counter = self.noise_period
end

function SN76489:_tick()
	for i = 1, 3 do
		local t = self.tone[i]
		t.counter = t.counter - 1
		if t.counter <= 0 then
			t.counter = (t.period < 2) and 1 or t.period
			t.output  = -t.output
		end
	end

	self.noise_counter = self.noise_counter - 1
	if self.noise_counter <= 0 then
		local p = (self.noise_period < 1) and 1 or self.noise_period
		self.noise_counter = p

		local feedback
		if self.noise_mode == 1 then
			feedback = parity16(bit.band(self.lfsr, TAPPED_BITS))
		else
			feedback = bit.band(self.lfsr, 1)
		end
		self.lfsr = bit.bor(
			bit.rshift(self.lfsr, 1),
			bit.lshift(feedback, 15)
		)

		self.noise_output = (bit.band(self.lfsr, 1) == 1) and 1 or -1
	end
end

function SN76489:_current_amp()
	local sum = 0
	for i = 1, 3 do
		sum = sum + self.tone[i].output * VOL[self.vol[i]]
	end
	sum = sum + self.noise_output * VOL[self.vol[4]]
	return sum / 4
end

function SN76489:render(buf, off, n)
	off = off or 0

	for frame = 0, n - 1 do
		local ticks_needed   = self.ticks_per_sample
		local integrated_sum = 0
		local amp = self:_current_amp()

		while ticks_needed > 0 do
			if self.time_to_tick <= ticks_needed then
				integrated_sum    = integrated_sum + amp * self.time_to_tick
				ticks_needed      = ticks_needed - self.time_to_tick
				self:_tick()
				self.time_to_tick = 1
				amp = self:_current_amp()
			else
				integrated_sum    = integrated_sum + amp * ticks_needed
				self.time_to_tick = self.time_to_tick - ticks_needed
				ticks_needed      = 0
			end
		end

		local s = math.floor(integrated_sum / self.ticks_per_sample)
		if s >  32767 then s =  32767 end
		if s < -32768 then s = -32768 end

		buf[(off + frame) * 2]     = s
		buf[(off + frame) * 2 + 1] = s

		local wp = self.wave_pos % WAVE_SIZE + 1
		self.wave_bufs[1][wp] = self.tone[1].output * VOL[self.vol[1]] * INV_32767
		self.wave_bufs[2][wp] = self.tone[2].output * VOL[self.vol[2]] * INV_32767
		self.wave_bufs[3][wp] = self.tone[3].output * VOL[self.vol[3]] * INV_32767
		self.wave_bufs[4][wp] = self.noise_output   * VOL[self.vol[4]] * INV_32767
		self.wave_pos = wp
	end
end

SN76489.descriptor = {
	id          = "sn76489",
	clock_field = "sn76489_clock",
	gain        = 0.15625,
	new = function(clock, hdr)
		return SN76489.new(clock)
	end,
	commands = {
		sn76489       = function(chip, reg, val) chip:write(val) end,
		psg_gg_stereo = function(chip, reg, val) chip:write(val) end,
	},
	render = function(chip, buf, off, n)
		chip:render(buf, off, n)
	end,
}

return SN76489
