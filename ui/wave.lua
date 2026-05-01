local wave      = {}
local WAVE_SIZE = 256
local _pts      = {}

do
	for i = 1, WAVE_SIZE * 2 do _pts[i] = 0 end
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
	local step = w / WAVE_SIZE
	for i = 0, WAVE_SIZE - 1 do
		local idx       = (wave_pos - WAVE_SIZE + i) % WAVE_SIZE + 1
		_pts[i * 2 + 1] = x + i * step
		_pts[i * 2 + 2] = cy - (buf[idx] or 0) * half
	end
	love.graphics.setLineWidth(1.5)
	love.graphics.line(_pts)
end

wave.WAVE_SIZE = WAVE_SIZE
return wave
