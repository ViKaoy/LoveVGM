-- YM2612 FM implementation.
-- Reference:
--   https://jsgroth.dev/blog/posts/emulating-ym2612-part-1/ and all the next pages

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
	typedef struct {
		uint8_t regs[2][256];
	} YM2612Regs;
]]

local WAVE_SIZE = 256

local YM2612 = {}
YM2612.__index = YM2612

YM2612.CONFIG = {
	enable_quantization  = true,
	enable_ladder_effect = true,
}

YM2612.SAMPLE_RATE = 53693175 / 7 / 6 / 24

local RATE_SCALE = (53693175 / 7 / 6 / 24) / 44100

--   DETUNE_TABLE[key_code*4+detunebits01]
local DETUNE_TABLE = ffi.new("uint8_t[128]", {
	0,0,1,2,  0,0,1,2,  0,0,1,2,  0,0,1,2,
	0,1,2,2,  0,1,2,3,  0,1,2,3,  0,1,2,3,
	0,1,2,4,  0,1,3,4,  0,1,3,4,  0,1,3,5,
	0,2,4,5,  0,2,4,6,  0,2,4,6,  0,2,5,7,
	0,2,5,8,  0,3,6,8,  0,3,6,9,  0,3,7,10,
	0,4,8,11, 0,4,8,12, 0,4,9,13, 0,5,10,14,
	0,5,11,16,0,6,12,17,0,6,13,19,0,7,14,20,
	0,8,16,22,0,8,16,22,0,8,16,22,0,8,16,22,
})
local LFO_DIVIDERS = ffi.new("uint16_t[8]", {108, 77, 71, 67, 62, 44, 8, 5})
local VIBRATO_TABLE = ffi.new("uint8_t[64]", {
	 0,  0,  0,  0,  0,  0,  0,  0,
	 0,  0,  0,  0,  4,  4,  4,  4,
	 0,  0,  0,  4,  4,  4,  8,  8,
	 0,  0,  4,  4,  8,  8, 12, 12,
	 0,  0,  4,  8,  8,  8, 12, 16,
	 0,  0,  8, 12, 16, 16, 20, 24,
	 0,  0, 16, 24, 32, 32, 40, 48,
	 0,  0, 32, 48, 64, 64, 80, 96,
})
local ADSR_PHASE = {
	ATTACK  = 1, DECAY   = 2,
	SUSTAIN = 3, RELEASE = 4,
}
local EG_INC_TABLE = ffi.new("uint8_t[512]", {
	0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,1,0,1,0,1,0,1, 0,1,0,1,0,1,0,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,0,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,0,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	0,1,0,1,0,1,0,1, 0,1,0,1,1,1,0,1, 0,1,1,1,0,1,1,1, 0,1,1,1,1,1,1,1,
	1,1,1,1,1,1,1,1, 1,1,1,2,1,1,1,2, 1,2,1,2,1,2,1,2, 1,2,2,2,1,2,2,2,
	2,2,2,2,2,2,2,2, 2,2,2,4,2,2,2,4, 2,4,2,4,2,4,2,4, 2,4,4,4,2,4,4,4,
	4,4,4,4,4,4,4,4, 4,4,4,8,4,4,4,8, 4,8,4,8,4,8,4,8, 4,8,8,8,4,8,8,8,
	8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8, 8,8,8,8,8,8,8,8,
})

local LOG_SINE_TABLE = ffi.new("uint16_t[256]")
for i = 0, 255 do
	local phase = ((2 * i + 1) / 512) * (math.pi / 2)
	LOG_SINE_TABLE[i] = math.floor(-(math.log(math.sin(phase)) / math.log(2)) * 256 + 0.5)
end

local POW2_TABLE = ffi.new("uint16_t[256]")
for i = 0, 255 do
	POW2_TABLE[i] = math.floor(math.pow(2, -((i + 1) / 256)) * 2048 + 0.5)
end

ffi.cdef[[
typedef struct {
	uint16_t mod2     : 4;
	uint16_t mod3     : 4;
	uint16_t mod4     : 4;
	uint16_t carriers : 4;
} alg_t;
]]

local ALG = ffi.new("alg_t[8]", {
	{0x1, 0x2, 0x4, 0x8}, -- 0: 1→2→3→4
	{0x0, 0x3, 0x4, 0x8}, -- 1: (1+2)→3→4
	{0x0, 0x2, 0x5, 0x8}, -- 2: 2→3, (1+3)→4
	{0x1, 0x0, 0x6, 0x8}, -- 3: 1→2, (2+3)→4
	{0x1, 0x0, 0x4, 0xa}, -- 4: 1→2, 3→4, out: 2+4
	{0x1, 0x1, 0x1, 0xe}, -- 5: 1→{2,3,4}
	{0x1, 0x0, 0x0, 0xe}, -- 6: 1→2,      out: 2+3+4
	{0x0, 0x0, 0x0, 0xf}, -- 7: all free, out: 1+2+3+4
})

local op_buf = ffi.new("int32_t[4]")

local function compute_key_code(f_number, block)
	local f11 = bit.band(bit.rshift(f_number, 10), 1)
	local f10 = bit.band(bit.rshift(f_number,  9), 1)
	local f9  = bit.band(bit.rshift(f_number,  8), 1)
	local f8  = bit.band(bit.rshift(f_number,  7), 1)
	local b0
	if f11 == 1 then
		b0 = (f10 == 1 or f9 == 1 or f8 == 1) and 1 or 0
	else
		b0 = (f10 == 1 and f9 == 1 and f8 == 1) and 1 or 0
	end
	return block * 4 + f11 * 2 + b0
end

local function compute_vibrato_f_num(f_number, lfo_counter, vibrato_level)
	local shifted = bit.lshift(f_number, 1)
	if vibrato_level == 0 then
		return shifted
	end
	local lfo_high = bit.rshift(lfo_counter, 2)
	local lfo_fm_idx
	if bit.band(lfo_high, 8) == 0 then
		lfo_fm_idx = bit.band(lfo_high, 7) + 1
	else
		lfo_fm_idx = 8 - bit.band(lfo_high, 7)
	end
	local multiplier = VIBRATO_TABLE[vibrato_level * 8 + lfo_fm_idx - 1]
	local delta = 0
	for i = 4, 10 do
		if bit.band(bit.rshift(f_number, i), 1) ~= 0 then
			delta = delta + bit.rshift(multiplier, 10 - i)
		end
	end
	local fm_f_num
	if bit.band(lfo_high, 16) == 0 then
		fm_f_num = shifted + delta
	else
		fm_f_num = shifted - delta
	end
	return bit.band(fm_f_num, 0xFFF)
end

local function compute_tremolo(lfo_counter, am_sensitivity)
	if am_sensitivity == 0 then return 0 end
	local lfo_am
	if bit.band(lfo_counter, 64) == 0 then
		lfo_am = bit.bxor(bit.band(lfo_counter, 0x3F), 0x3F)
	else
		lfo_am = bit.band(lfo_counter, 0x3F)
	end
	lfo_am = bit.lshift(lfo_am, 1)
	if am_sensitivity == 3 then
		return lfo_am
	elseif am_sensitivity == 2 then
		return bit.rshift(lfo_am, 1)
	else
		return bit.rshift(lfo_am, 3)
	end
end

local function make_operator()
	return {
		counter         = 0,
		f_number        = 0,
		block           = 0,
		detune          = 0,
		multiple        = 0,
		key_on          = false,
		eg_phase        = ADSR_PHASE.RELEASE,
		eg_level        = 0x3FF,
		total_level     = 0,
		attack_rate     = 0,
		decay_rate      = 0,
		sustain_rate    = 0,
		release_rate    = 1,
		sustain_level   = 0,
		key_scale_level = 0,
		lfo_am_enabled  = false,
		-- SSG-EG
		ssg_enabled   = false,
		ssg_attack    = false,
		ssg_alternate = false,
		ssg_hold      = false,
		ssg_invert    = false,
	}
end

local function make_channel()
	return {
		f_number          = 0,
		block             = 0,
		f_number_pending  = 0,
		block_pending     = 0,
		algorithm         = 0,
		feedback          = 0,
		pan_l             = true,
		pan_r             = true,
		lfo_fm_sensitivity = 0,
		lfo_am_sensitivity = 0,
		op1_prev          = {0, 0},
		operators = {
			make_operator(),
			make_operator(),
			make_operator(),
			make_operator(),
		},
	}
end

local function phase_clock(op, fm_f_num)
	local increment = bit.band(bit.rshift(bit.lshift(fm_f_num, op.block), 2), 0x1FFFF)

	local key_code = compute_key_code(op.f_number, op.block)
	-- DETUNE_TABLE[key_code * 4 + (detune & 3)]  — both 0-based
	local dt_mag   = DETUNE_TABLE[key_code * 4 + bit.band(op.detune, 3)]

	if bit.band(op.detune, 4) ~= 0 then
		increment = bit.band(increment - dt_mag, 0x1FFFF)
	else
		increment = bit.band(increment + dt_mag, 0x1FFFF)
	end

	if op.multiple == 0 then
		increment = bit.rshift(increment, 1)
	else
		increment = increment * op.multiple
	end

	op.counter = (op.counter + increment * RATE_SCALE) % 0x100000
end

local function ssg_update(op, phase_counter)
	if not op.ssg_enabled then return phase_counter end
	if op.eg_level < 0x200 then return phase_counter end

	if op.ssg_alternate then
		op.ssg_invert = not op.ssg_invert or op.ssg_hold
	end

	if not op.ssg_alternate and not op.ssg_hold then
		phase_counter = 0
	end

	if not op.ssg_hold and op.eg_phase ~= ADSR_PHASE.RELEASE then
		op.eg_phase = ADSR_PHASE.ATTACK
		local key_code = compute_key_code(op.f_number, op.block)
		local rks  = bit.rshift(key_code, 3 - op.key_scale_level)
		local rate = op.attack_rate == 0 and 0 or math.min(63, bit.lshift(op.attack_rate, 1) + rks)
		if rate >= 62 then
			op.eg_level = 0
		end
	end

	local inverted = bit.bxor(op.ssg_attack and 1 or 0, op.ssg_invert and 1 or 0) == 1
	if op.ssg_hold and op.eg_phase ~= ADSR_PHASE.ATTACK and not inverted then
		op.eg_level = 0x3FF
	end

	if op.eg_phase == ADSR_PHASE.RELEASE then
		op.eg_level = 0x3FF
	end

	return phase_counter
end

local function eg_clock(op, ch_f_number, ch_block, global_cycles)
	if op.eg_phase == ADSR_PHASE.ATTACK and op.eg_level == 0 then
		op.eg_phase = ADSR_PHASE.DECAY
	end

	if op.eg_phase == ADSR_PHASE.DECAY then
		local sl_steps  = op.sustain_level == 15 and 31 or op.sustain_level
		local sl_target = bit.lshift(sl_steps, 5)
		if op.eg_level >= sl_target then
			op.eg_phase = ADSR_PHASE.SUSTAIN
		end
	end

	local r = 0
	if     op.eg_phase == ADSR_PHASE.ATTACK  then r = op.attack_rate
	elseif op.eg_phase == ADSR_PHASE.DECAY   then r = op.decay_rate
	elseif op.eg_phase == ADSR_PHASE.SUSTAIN then r = op.sustain_rate
	elseif op.eg_phase == ADSR_PHASE.RELEASE then r = bit.lshift(op.release_rate, 1) + 1
	end

	local key_code = compute_key_code(ch_f_number, ch_block)
	local rks  = bit.rshift(key_code, 3 - op.key_scale_level)
	local rate = (r == 0) and 0 or math.min(63, bit.lshift(r, 1) + rks)

	local shift = math.max(0, 11 - math.floor(rate / 4))
	local mask  = bit.lshift(1, shift) - 1

	if bit.band(global_cycles, mask) == 0 then
		-- EG_INC_TABLE[rate * 8 + (global_cycles >> shift) & 7]  — both 0-based
		local inc = EG_INC_TABLE[rate * 8 + bit.band(bit.rshift(global_cycles, shift), 7)]

		if inc > 0 then
			if op.eg_phase == ADSR_PHASE.ATTACK then
				local change = bit.arshift(inc * bit.bnot(op.eg_level), 4)
				op.eg_level  = math.max(0, op.eg_level + change)
				if op.eg_level == 0 then
					op.eg_phase = ADSR_PHASE.DECAY
				end
			else
				if op.ssg_enabled then
					if op.eg_level < 0x200 then
						op.eg_level = math.min(0x3FF, op.eg_level + inc * 4)
					end
				else
					op.eg_level = math.min(0x3FF, op.eg_level + inc)
				end
				if op.eg_phase == ADSR_PHASE.DECAY then
					local sl_steps  = op.sustain_level == 15 and 31 or op.sustain_level
					local sl_target = bit.lshift(sl_steps, 5)
					if op.eg_level >= sl_target then
						op.eg_phase = ADSR_PHASE.SUSTAIN
					end
				end
			end
		end
	end
end

local function clock_operator(op, phase_offset, tremolo_att)
	local phase = bit.band(math.floor(op.counter / 1024) + phase_offset, 0x3FF)

	local table_idx
	if bit.band(phase, 0x100) == 0 then
		table_idx = bit.band(phase, 0xFF)
	else
		table_idx = 0x1FF - bit.band(phase, 0x1FF)
	end

	local phase_att = LOG_SINE_TABLE[table_idx]
	local tl_added  = bit.lshift(op.total_level, 3)

	local raw_level = op.eg_level
	if op.ssg_enabled and op.eg_phase ~= ADSR_PHASE.RELEASE then
		local inv = bit.bxor(op.ssg_attack and 1 or 0, op.ssg_invert and 1 or 0) == 1
		if inv then
			raw_level = bit.band(0x200 - raw_level, 0x3FF)
		end
	end

	local env_raw   = raw_level + tl_added
	if op.lfo_am_enabled then
		env_raw = env_raw + tremolo_att
	end
	local env_level = math.min(0x3FF, env_raw)

	local total_att = phase_att + bit.lshift(env_level, 2)
	local fract     = bit.band(total_att, 0xFF)
	local int_part  = bit.rshift(total_att, 8)

	local sample = 0
	if int_part < 13 then
		sample = bit.rshift(bit.lshift(POW2_TABLE[fract], 2), int_part)
	end

	if bit.band(phase, 0x200) ~= 0 then
		sample = -sample
	end

	return sample
end

local function quantize_carrier(val)
	if YM2612.CONFIG.enable_quantization then
		return bit.band(val, -32)
	end
	return val
end

local function apply_ladder(sample, is_panned)
	if not YM2612.CONFIG.enable_ladder_effect then
		return is_panned and sample or 0
	end
	if not is_panned then
		return (sample >= 0) and 128 or -128
	else
		return sample + ((sample >= 0) and 128 or -96)
	end
end

function YM2612.new()
	local self = setmetatable({}, YM2612)

	self._regs = ffi.new("YM2612Regs")

	self.dac_enabled  = false
	self.dac_sample   = 0

	self.pcm_bank     = nil
	self.pcm_bank_len = 0
	self.pcm_bank_pos = 0

	self.ch3_special  = false

	self.eg_timer      = 0
	self.global_cycles = 1

	self.timer_a_interval        = 0
	self.timer_a_counter         = 0
	self.timer_a_load            = false
	self.timer_a_overflow_flag   = false
	self.timer_a_overflow_enabled = false
	self.timer_b_interval        = 0
	self.timer_b_counter         = 0
	self.timer_b_load            = false
	self.timer_b_overflow_flag   = false
	self.timer_b_overflow_enabled = false
	self.timer_b_divider         = 0
	self.timer_frac              = 0

	self.lfo_enabled   = false
	self.lfo_frequency = 0
	self.lfo_counter   = 0
	self.lfo_divider   = 0

	self.channels = {}
	for i = 1, 6 do
		self.channels[i] = make_channel()
	end

	self.wave_bufs = {}
	self.wave_pos  = 0
	for i = 1, 6 do
		local t = {}
		for j = 1, WAVE_SIZE do t[j] = 0 end
		self.wave_bufs[i] = t
	end
	self.wave_labels = { "CH1", "CH2", "CH3", "CH4", "CH5", "CH6" }

	return self
end

function YM2612:read_status()
	local v = 0
	if self.timer_a_overflow_flag then v = bit.bor(v, 0x01) end
	if self.timer_b_overflow_flag then v = bit.bor(v, 0x02) end
	return v
end

function YM2612:write(port, reg, val)
	self._regs.regs[port][reg] = bit.band(val, 0xFF)

	if port == 0 and reg == 0x22 then
		local new_enabled = bit.band(val, 0x08) ~= 0
		if not new_enabled then
			self.lfo_counter = 0
			self.lfo_divider = 0
		end
		self.lfo_enabled   = new_enabled
		self.lfo_frequency = bit.band(val, 0x07)
		return
	end

	if port == 0 and reg == 0x24 then
		self.timer_a_interval = bit.bor(bit.lshift(val, 2), bit.band(self.timer_a_interval, 0x03))
		return
	end

	if port == 0 and reg == 0x25 then
		self.timer_a_interval = bit.bor(bit.band(self.timer_a_interval, 0x3FC), bit.band(val, 0x03))
		return
	end

	if port == 0 and reg == 0x26 then
		self.timer_b_interval = val
		return
	end

	if port == 0 and reg == 0x27 then
		self.ch3_special = bit.band(val, 0xC0) ~= 0

		local new_ta = bit.band(val, 0x01) ~= 0
		if new_ta and not self.timer_a_load then
			self.timer_a_counter = self.timer_a_interval
		end
		self.timer_a_load = new_ta

		local new_tb = bit.band(val, 0x02) ~= 0
		if new_tb and not self.timer_b_load then
			self.timer_b_counter = self.timer_b_interval
			self.timer_b_divider = 0
		end
		self.timer_b_load = new_tb

		self.timer_a_overflow_enabled = bit.band(val, 0x04) ~= 0
		self.timer_b_overflow_enabled = bit.band(val, 0x08) ~= 0

		if bit.band(val, 0x10) ~= 0 then self.timer_a_overflow_flag = false end
		if bit.band(val, 0x20) ~= 0 then self.timer_b_overflow_flag = false end
		return
	end

	if port == 0 and reg == 0x2B then
		self.dac_enabled = bit.band(val, 0x80) ~= 0
		return
	end

	if port == 0 and reg == 0x2A then
		self.dac_sample = bit.band(val, 0xFF)
		return
	end

	if port == 0 and reg == 0x28 then
		local ch_bits = bit.band(val, 0x07)
		if ch_bits ~= 3 and ch_bits ~= 7 then
			local ch_idx = (ch_bits < 4) and (ch_bits + 1) or ch_bits
			local ch = self.channels[ch_idx]
			for op_i = 0, 3 do
				local on = bit.band(bit.rshift(val, 4 + op_i), 1) ~= 0
				local op = ch.operators[op_i + 1]

				if on and not op.key_on then
					op.ssg_invert = false
					op.counter  = 0
					op.eg_phase = ADSR_PHASE.ATTACK

					local key_code = compute_key_code(ch.f_number, ch.block)
					local rks  = bit.rshift(key_code, 3 - op.key_scale_level)
					local rate = op.attack_rate == 0 and 0 or math.min(63, bit.lshift(op.attack_rate, 1) + rks)
					if rate >= 62 then
						op.eg_level = 0
						op.eg_phase = ADSR_PHASE.DECAY
					end
				elseif not on and op.key_on then
					if op.ssg_enabled then
						local inv = bit.bxor(op.ssg_attack and 1 or 0, op.ssg_invert and 1 or 0) == 1
						if inv then
							op.eg_level = bit.band(0x200 - op.eg_level, 0x3FF)
						end
					end
					op.eg_phase = ADSR_PHASE.RELEASE
				end

				op.key_on = on
			end
		end
		return
	end

	if reg >= 0x30 and reg <= 0x9F then
		local ch_off = bit.band(reg, 0x03)
		if ch_off == 3 then return end
		local ch_idx = port * 3 + ch_off + 1
		local op_idx = bit.bor(bit.band(bit.rshift(reg, 3), 1), bit.band(bit.rshift(reg, 1), 2)) + 1
		local op = self.channels[ch_idx].operators[op_idx]

		if     reg <= 0x3F then
			op.multiple        = bit.band(val, 0x0F)
			op.detune          = bit.band(bit.rshift(val, 4), 0x07)
		elseif reg <= 0x4F then
			op.total_level     = bit.band(val, 0x7F)
		elseif reg <= 0x5F then
			op.attack_rate     = bit.band(val, 0x1F)
			op.key_scale_level = bit.rshift(val, 6)
		elseif reg <= 0x6F then
			op.decay_rate      = bit.band(val, 0x1F)
			op.lfo_am_enabled  = bit.band(val, 0x80) ~= 0
		elseif reg <= 0x7F then
			op.sustain_rate    = bit.band(val, 0x1F)
		elseif reg <= 0x8F then
			op.release_rate    = bit.band(val, 0x0F)
			op.sustain_level   = bit.rshift(val, 4)
		elseif reg <= 0x9F then
			op.ssg_enabled   = bit.band(val, 0x08) ~= 0
			op.ssg_attack    = bit.band(val, 0x04) ~= 0
			op.ssg_alternate = bit.band(val, 0x02) ~= 0
			op.ssg_hold      = bit.band(val, 0x01) ~= 0
		end
		return
	end

	if reg >= 0xA0 and reg <= 0xA2 then
		local ch_idx = port * 3 + bit.band(reg, 0x03) + 1
		local ch = self.channels[ch_idx]
		ch.f_number = bit.bor(val, bit.lshift(ch.f_number_pending, 8))
		ch.block    = ch.block_pending
		for _, op in ipairs(ch.operators) do
			op.f_number = ch.f_number
			op.block    = ch.block
		end
		return
	end

	if reg >= 0xA4 and reg <= 0xA6 then
		local ch_idx = port * 3 + bit.band(reg, 0x03) + 1
		local ch = self.channels[ch_idx]
		ch.f_number_pending = bit.band(val, 0x07)
		ch.block_pending    = bit.band(bit.rshift(val, 3), 0x07)
		return
	end

	if reg >= 0xB0 and reg <= 0xB6 then
		local ch_off = bit.band(reg, 0x03)
		if ch_off == 3 then return end
		local ch_idx = port * 3 + ch_off + 1
		local ch = self.channels[ch_idx]

		if reg <= 0xB2 then
			ch.algorithm = bit.band(val, 0x07)
			ch.feedback  = bit.band(bit.rshift(val, 3), 0x07)
		else
			ch.pan_l             = bit.band(val, 0x80) ~= 0
			ch.pan_r             = bit.band(val, 0x40) ~= 0
			ch.lfo_am_sensitivity = bit.band(bit.rshift(val, 4), 0x03)
			ch.lfo_fm_sensitivity = bit.band(val, 0x07)
		end
		return
	end
end

function YM2612:read_reg(port, reg)
	return self._regs.regs[port][reg]
end

function YM2612:set_pcm_bank(data_ptr, data_len)
	self.pcm_bank     = data_ptr
	self.pcm_bank_len = data_len
	self.pcm_bank_pos = 0
end

function YM2612:pcm_seek(offset)
	self.pcm_bank_pos = offset
end

function YM2612:pcm_next()
	if not self.pcm_bank or self.pcm_bank_pos >= self.pcm_bank_len then
		return 0x80
	end
	local v = self.pcm_bank[self.pcm_bank_pos]
	self.pcm_bank_pos = self.pcm_bank_pos + 1
	return v
end

function YM2612:render(buf, off, n)
	off = off or 0
	for frame = 0, n - 1 do

		self.timer_frac = self.timer_frac + RATE_SCALE
		while self.timer_frac >= 1 do
			self.timer_frac = self.timer_frac - 1

			if self.timer_a_load then
				self.timer_a_counter = (self.timer_a_counter + 1) % 1024
				if self.timer_a_counter == 0 then
					self.timer_a_counter = self.timer_a_interval
					if self.timer_a_overflow_enabled then
						self.timer_a_overflow_flag = true
					end
				end
			end

			self.timer_b_divider = self.timer_b_divider + 1
			if self.timer_b_divider >= 16 then
				self.timer_b_divider = 0
				if self.timer_b_load then
					self.timer_b_counter = (self.timer_b_counter + 1) % 256
					if self.timer_b_counter == 0 then
						self.timer_b_counter = self.timer_b_interval
						if self.timer_b_overflow_enabled then
							self.timer_b_overflow_flag = true
						end
					end
				end
			end
		end

		if self.lfo_enabled then
			self.lfo_divider = self.lfo_divider + RATE_SCALE
			local lfo_div = LFO_DIVIDERS[self.lfo_frequency]
			if self.lfo_divider >= lfo_div then
				self.lfo_divider = self.lfo_divider - lfo_div
				self.lfo_counter = (self.lfo_counter + 1) % 128
			end
		end

		self.eg_timer = self.eg_timer + 1
		local tick_eg = false
		if self.eg_timer >= 3 then
			self.eg_timer  = 0
			self.global_cycles = self.global_cycles + 1
			if self.global_cycles >= 4096 then self.global_cycles = 1 end
			tick_eg = true
		end

		local sum_l = 0
		local sum_r = 0
		local wave_wp = self.wave_pos % WAVE_SIZE + 1

		for ch_i = 1, 6 do
			local ch          = self.channels[ch_i]
			local tremolo_att = compute_tremolo(self.lfo_counter, ch.lfo_am_sensitivity)
			local ch_op_fm    = compute_vibrato_f_num(ch.f_number, self.lfo_counter, ch.lfo_fm_sensitivity)

			for op_i = 1, 4 do
				local op = ch.operators[op_i]
				op.counter = ssg_update(op, op.counter)
				if tick_eg then
					eg_clock(op, ch.f_number, ch.block, self.global_cycles)
				end
				local op_fm = (self.ch3_special and ch_i == 3)
					and compute_vibrato_f_num(op.f_number, self.lfo_counter, ch.lfo_fm_sensitivity)
					or  ch_op_fm
				phase_clock(op, op_fm)
			end

			local out = 0

			if ch_i == 6 and self.dac_enabled then
				out = (self.dac_sample - 128) * 64
			else
				local fb_val = 0
				if ch.feedback > 0 then
					fb_val = bit.arshift(ch.op1_prev[1] + ch.op1_prev[2], 10 - ch.feedback)
				end

				local o1 = clock_operator(ch.operators[1], fb_val, tremolo_att)
				ch.op1_prev[2] = ch.op1_prev[1]
				ch.op1_prev[1] = o1

				local cfg = ALG[ch.algorithm]
				op_buf[0], op_buf[1], op_buf[2], op_buf[3] = o1, 0, 0, 0
				for i = 1, 3 do
					local mask = i == 1 and cfg.mod2 or i == 2 and cfg.mod3 or cfg.mod4
					local mod = 0
					for b = 0, 3 do
						if bit.band(mask, bit.lshift(1, b)) ~= 0 then
							mod = mod + op_buf[b]
						end
					end
					op_buf[i] = clock_operator(ch.operators[i + 1], bit.arshift(mod, 1), tremolo_att)
				end

				for b = 0, 3 do
					if bit.band(cfg.carriers, bit.lshift(1, b)) ~= 0 then
						out = out + quantize_carrier(op_buf[b])
					end
				end
			end

			local out_l = apply_ladder(out, ch.pan_l)
			local out_r = apply_ladder(out, ch.pan_r)

			if out_l >  8191 then out_l =  8191 elseif out_l < -8192 then out_l = -8192 end
			if out_r >  8191 then out_r =  8191 elseif out_r < -8192 then out_r = -8192 end

			sum_l = sum_l + out_l / 8192
			sum_r = sum_r + out_r / 8192

			local wv = (out_l + out_r) / (2 * 8192)
			if wv >  1 then wv =  1 elseif wv < -1 then wv = -1 end
			self.wave_bufs[ch_i][wave_wp] = wv
		end
		self.wave_pos = wave_wp

		local s_l = sum_l / 6
		local s_r = sum_r / 6

		if s_l > 1 then s_l = 1 elseif s_l < -1 then s_l = -1 end
		if s_r > 1 then s_r = 1 elseif s_r < -1 then s_r = -1 end

		buf[(off + frame) * 2]     = math.floor(s_l * 32767)
		buf[(off + frame) * 2 + 1] = math.floor(s_r * 32767)
	end
end

YM2612.descriptor = {
	id          = "ym2612",
	clock_field = "ym2612_clock",
	gain        = 1.0,
	new = function(clock, hdr)
		return YM2612.new()
	end,
	commands = {
		ym2612_p0 = function(chip, reg, val) chip:write(0, reg, val) end,
		ym2612_p1 = function(chip, reg, val) chip:write(1, reg, val) end,
	},
	events = {
		on_data_block = function(chip, block_type, ptr, len)
			if block_type == 0x00 then
				chip:set_pcm_bank(ptr, len)
			end
		end,
		on_dac_bank_write = function(chip, wait_n)
			chip.dac_sample = chip:pcm_next()
		end,
		on_seek = function(chip, offset)
			chip:pcm_seek(offset)
		end,
	},
	render = function(chip, buf, off, n)
		chip:render(buf, off, n)
	end,
	wave_extra = function(chip)
		return { dac_ch = chip.dac_enabled and 6 or nil }
	end,
}

return YM2612
