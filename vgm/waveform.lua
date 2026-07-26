local WAVE_SIZE = 512

local Waveform = {}
Waveform.__index = Waveform

function Waveform.new(labels, size)
	local self = setmetatable({}, Waveform)
	self.size   = size or WAVE_SIZE
	self.labels = labels
	self.pos    = 0
	self.bufs   = {}
	for i = 1, #labels do
		local buf = {}
		for j = 1, self.size do buf[j] = 0 end
		self.bufs[i] = buf
	end
	return self
end

function Waveform:advance()
	self.pos = self.pos % self.size + 1
	return self.pos
end

function Waveform:set(idx, value)
	self.bufs[idx][self.pos] = value
end

function Waveform:trigger_offset(channel, window)
	local buf  = self.bufs[channel]
	local size = self.size
	window = window or math.floor(size / 2)
	local half_win = math.floor(window / 2)

	local function at(i)
		local idx = self.pos - i
		idx = ((idx - 1) % size) + 1
		return buf[idx]
	end

	local lo_bound = half_win
	local hi_bound = size - 1 - half_win
	local i0       = math.floor(size / 2)
	local i_cross  = i0

	for radius = 0, hi_bound - lo_bound do
		local hi = i0 + radius
		local lo = i0 - radius
		if hi <= hi_bound and at(hi + 1) <= 0 and at(hi) > 0 then
			i_cross = hi
			break
		end
		if lo >= lo_bound and at(lo + 1) <= 0 and at(lo) > 0 then
			i_cross = lo
			break
		end
	end

	local crossing_idx = self.pos - i_cross
	crossing_idx = ((crossing_idx - 1) % size) + 1

	local start_idx = crossing_idx - half_win
	start_idx = ((start_idx - 1) % size) + 1

	return start_idx, window
end

return Waveform
