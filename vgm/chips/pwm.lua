local bit = require("bit")

local PWM = {}
PWM.__index = PWM

local DEFAULT_CLOCK = 23011361
local DEFAULT_CYCLE = 1040
local FIFO_DEPTH    = 3
local OUTPUT_RATE   = 44100

function PWM.new(clock)
	local self      = setmetatable({}, PWM)
	self.clock      = clock and clock ~= 0 and clock or DEFAULT_CLOCK
	self.cycle      = DEFAULT_CYCLE
	self.offset     = math.floor(DEFAULT_CYCLE / 2)
	self._fifo_l    = {}
	self._fifo_r    = {}
	self.left       = math.floor(DEFAULT_CYCLE / 2)
	self.right      = math.floor(DEFAULT_CYCLE / 2)
	self._frac      = 0
	self._step_inc  = self.clock / (DEFAULT_CYCLE * OUTPUT_RATE)
	self._inv_offset = 1 / self.offset
	return self
end

function PWM:write(reg, val)
	local v = bit.band(val, 0xFFF)
	if reg == 0x00 then
	elseif reg == 0x01 then
		local c = bit.band(val, 0xFFF)
		if c < 1 then c = 1 end
		self.cycle       = c
		self.offset      = math.floor(c / 2)
		self._step_inc   = self.clock / (c * OUTPUT_RATE)
		self._inv_offset = self.offset > 0 and (1 / self.offset) or 1
	elseif reg == 0x02 then
		if #self._fifo_l < FIFO_DEPTH then
			self._fifo_l[#self._fifo_l + 1] = v
		end
	elseif reg == 0x03 then
		if #self._fifo_r < FIFO_DEPTH then
			self._fifo_r[#self._fifo_r + 1] = v
		end
	elseif reg == 0x04 then
		if #self._fifo_l < FIFO_DEPTH then
			self._fifo_l[#self._fifo_l + 1] = v
		end
		if #self._fifo_r < FIFO_DEPTH then
			self._fifo_r[#self._fifo_r + 1] = v
		end
	end
end

function PWM:_normalize(width)
	local s = (width - self.offset) * self._inv_offset
	if s >  1 then return  1 end
	if s < -1 then return -1 end
	return s
end

function PWM:step()
	self._frac = self._frac + self._step_inc
	while self._frac >= 1 do
		self._frac = self._frac - 1
		if #self._fifo_l > 0 then
			self.left  = table.remove(self._fifo_l, 1)
		end
		if #self._fifo_r > 0 then
			self.right = table.remove(self._fifo_r, 1)
		end
	end
	return self:_normalize(self.left), self:_normalize(self.right)
end

function PWM:render(buf, off, n)
	off = off or 0
	for i = 0, n - 1 do
		local L, R     = self:step()
		local li       = (off + i) * 2
		buf[li]        = math.floor(L * 32767)
		buf[li + 1]    = math.floor(R * 32767)
	end
end

function PWM:sample_rate()
	return self.clock / self.cycle
end

PWM.descriptor = {
	id          = "pwm",
	clock_field = "pwm_clock",
	gain        = 0.5,
	new = function(clock, hdr)
		local pwm_inst      = PWM.new(clock)
		local StreamControl = require("vgm.stream_control")
		return StreamControl.new(pwm_inst, { hq = true })
	end,
	commands = {
		pwm32x = function(sc, reg, val)
			local r = bit.band(bit.rshift(reg, 4), 0x07)
			local v = bit.bor(bit.lshift(bit.band(reg, 0x0F), 8), val)
			sc:write_chip(r, v)
		end,
	},
	events = {
		on_data_block     = function(sc, bt, ptr, len) sc:data_block(bt, ptr, len) end,
		on_dac_setup_chip = function(sc, ...) sc:setup_chip(...) end,
		on_dac_setup_data = function(sc, ...) sc:setup_data(...) end,
		on_dac_setup_freq = function(sc, ...) sc:setup_freq(...) end,
		on_dac_start      = function(sc, ...) sc:start_stream(...) end,
		on_dac_stop       = function(sc, ...) sc:stop_stream(...) end,
		on_dac_start_fast = function(sc, ...) sc:start_fast(...) end,
	},
	render = function(sc, buf, off, n)
		sc:render(buf, off, n)
	end,
	wave_active = function(sc)
		return sc:any_active()
	end,
}

return PWM
