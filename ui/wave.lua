local wave      = {}
local WAVE_SIZE = 512
local WINDOW    = 256
local HALF_WIN  = math.floor(WINDOW / 2)
local _pts      = {}

do
	for i = 1, WINDOW * 2 do _pts[i] = 0 end
end

local function find_crossing(buf, wave_pos)
	local function at(i)
		local idx = (wave_pos - WAVE_SIZE + i) % WAVE_SIZE + 1
		return buf[idx] or 0
	end

	local lo_bound = HALF_WIN
	local hi_bound = WAVE_SIZE - 1 - HALF_WIN
	local i0       = math.floor(WAVE_SIZE / 2)

	for radius = 0, hi_bound - lo_bound do
		local hi = i0 + radius
		local lo = i0 - radius
		if hi <= hi_bound and at(hi) <= 0 and at(hi + 1) > 0 then
			return hi
		end
		if lo >= lo_bound and at(lo) <= 0 and at(lo + 1) > 0 then
			return lo
		end
	end

	return i0
end

function wave.draw(bufs, ch, wave_pos, x, y, w, h, r, g, b, inactive)
	if inactive then
		love.graphics.setColor(r * 0.25, g * 0.25, b * 0.25, 0.4)
	else
		love.graphics.setColor(r, g, b, 0.95)
	end
	local buf  = bufs[ch]
	local half = h / 2
	local cy   = y + half

	local crossing = find_crossing(buf, wave_pos)
	local start_i  = crossing - HALF_WIN

	local step = w / WINDOW
	for i = 0, WINDOW - 1 do
		local idx       = (wave_pos - WAVE_SIZE + start_i + i) % WAVE_SIZE + 1
		_pts[i * 2 + 1] = x + i * step
		_pts[i * 2 + 2] = cy - (buf[idx] or 0) * half
	end

	love.graphics.setLineWidth(1.5)
	love.graphics.line(_pts)
end

wave.WAVE_SIZE = WAVE_SIZE
return wave
