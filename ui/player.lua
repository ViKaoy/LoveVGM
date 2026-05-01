local player_ui = {}
local theme     = require("ui.theme")
local wave_mod  = require("ui.wave")
local core      = require("ui.core")

local PAD      = 24
local BAR_H    = 12
local WAVE_PAD = 4
local BASE_HUE = 0.58

local _fonts
local _sample_rate

local _statuses = {}
local _rows     = {}

local function _hsv(h, s, v)
	h = h % 1
	local i = math.floor(h * 6) % 6
	local f = h * 6 - math.floor(h * 6)
	local p = v * (1 - s)
	local q = v * (1 - f * s)
	local t = v * (1 - (1 - f) * s)
	if     i == 0 then return v, t, p
	elseif i == 1 then return q, v, p
	elseif i == 2 then return p, v, t
	elseif i == 3 then return p, q, v
	elseif i == 4 then return t, p, v
	else               return v, p, q end
end

local function _fmt_time(sec)
	sec = math.max(0, sec)
	return ("%d:%02d"):format(math.floor(sec / 60), math.floor(sec) % 60)
end

local function _wave_row(group, label, clock, hue_start, hue_step, x, y, avail_w, cell_h)
	local n_ch   = #group.labels
	local gap    = 8 + WAVE_PAD * 2
	local cell_w = math.floor((avail_w - gap * (n_ch - 1)) / n_ch)

	local display_label = label
	if clock and clock > 0 then
		if clock >= 1e6 then
			display_label = label .. ("  %.2f MHz"):format(clock / 1e6)
		else
			display_label = label .. ("  %.0f Hz"):format(clock)
		end
	end

	love.graphics.setFont(_fonts.sm)
	love.graphics.setColor(0.45, 0.45, 0.60)
	love.graphics.print(display_label, x, y)
	y = y + _fonts.sm:getHeight() + 4

	for i = 1, n_ch do
		local r, g, b  = _hsv(hue_start + (i - 1) * hue_step, 0.62, 0.92)
		local cx       = x + (i - 1) * (cell_w + gap)
		local inactive = group.active and not group.active[i]
		local bx       = cx - WAVE_PAD
		local by       = y  - WAVE_PAD
		local bw       = cell_w + WAVE_PAD * 2
		local bh       = cell_h + WAVE_PAD * 2

		love.graphics.setColor(0, 0, 0, inactive and 0.15 or 0.35)
		love.graphics.rectangle("fill", bx, by, bw, bh, 4, 4)

		local sx, sy = love.graphics.transformPoint(bx, by)
		love.graphics.setScissor(math.floor(sx), math.floor(sy), bw, bh)
		wave_mod.draw(group.bufs, i, group.wave_pos, cx, y, cell_w, cell_h, r, g, b, inactive)
		love.graphics.setScissor()

		local lbl = group.labels[i]
		local lw  = _fonts.sm:getWidth(lbl)
		local dim = inactive and 0.30 or 0.70
		love.graphics.setColor(r * dim, g * dim, b * dim, inactive and 0.5 or 1)
		love.graphics.print(lbl, cx + math.floor((cell_w - lw) / 2), y + cell_h + 4)
	end

	return y + cell_h + _fonts.sm:getHeight() + 12
end

function player_ui.init(fonts, sample_rate)
	_fonts       = fonts
	_sample_rate = sample_rate
end

function player_ui.draw(p, W, H)
	local inf = p:info()
	local hdr = p.header
	local gd3 = inf.gd3

	local total        = inf.total_samples
	local loop_smp     = (inf.loop_offset and hdr.loop_samples > 0) and hdr.loop_samples or nil
	local loop_start_s = loop_smp and (total - loop_smp) or nil

	local pos_s = p:tell()
	if loop_start_s and loop_smp and pos_s > total then
		pos_s = loop_start_s + (pos_s - loop_start_s) % loop_smp
	end
	pos_s = math.min(pos_s, total)

	local bar_fill  = total > 0 and (pos_s / total) or 0
	local loop_frac = loop_start_s and (loop_start_s / total) or nil
	local past_loop = loop_frac and (bar_fill >= loop_frac)

	local y = PAD

	if gd3 then
		local game   = gd3.game   ~= "" and gd3.game   or ""
		local system = gd3.system ~= "" and gd3.system or ""
		local author = gd3.author ~= "" and gd3.author or ""
		local date   = gd3.date   ~= "" and gd3.date   or ""

		local full_w = W - PAD * 2
		local gutter = 16
		local sys_w  = _fonts.sm:getWidth(system)

		love.graphics.setFont(_fonts.md)
		love.graphics.setColor(0.75, 0.75, 0.85)
		core.drawTextScaled(game, PAD, y, full_w - (system ~= "" and (sys_w + gutter) or 0))

		love.graphics.setFont(_fonts.sm)
		love.graphics.setColor(0.50, 0.50, 0.65)
		core.drawTextScaled(system, PAD + full_w - sys_w, y + 2, sys_w, "right")
		y = y + 20

		love.graphics.setFont(_fonts.sm)
		local date_w = _fonts.sm:getWidth(date)
		love.graphics.setColor(0.45, 0.45, 0.60)
		core.drawTextScaled(author, PAD, y, full_w - (date ~= "" and (date_w + gutter) or 0))
		core.drawTextScaled(date, PAD + full_w - date_w, y, date_w, "right")
		y = y + 15
	else
		love.graphics.setFont(_fonts.lg)
		love.graphics.setColor(0.40, 0.40, 0.50)
		love.graphics.print("(no GD3 metadata)", PAD, y)
		y = y + 30
	end

	y = y + 8
	love.graphics.setColor(unpack(theme.DIVIDER))
	love.graphics.rectangle("fill", PAD, y, W - PAD * 2, 1)
	y = y + 10

	love.graphics.setFont(_fonts.sm)

	local ns = 0
	if inf.dac_enabled       then ns=ns+1; _statuses[ns]="DAC"                                     end
	if inf.rf5c164_active_ch then ns=ns+1; _statuses[ns]=("RF %dch"):format(inf.rf5c164_active_ch) end
	if inf.pwm_active        then ns=ns+1; _statuses[ns]="PWM"                                     end
	if not inf.looping       then ns=ns+1; _statuses[ns]="no loop"                                 end
	if inf.finished          then ns=ns+1; _statuses[ns]="ended"                                   end

	if ns > 0 then
		love.graphics.setFont(_fonts.sm)
		love.graphics.setColor(0.30, 0.75, 0.50)
		core.drawTextScaled(table.concat(_statuses, "  \xC2\xB7  ", 1, ns), PAD, y, W - PAD * 2)
		y = y + 15
	end

	local time_h = _fonts.sm:getHeight()
	local bar_y  = H - PAD - time_h - 10 - BAR_H
	local bar_x  = PAD
	local bar_w  = W - PAD * 2

	love.graphics.setColor(0.12, 0.12, 0.16)
	love.graphics.rectangle("fill", bar_x, bar_y, bar_w, BAR_H, BAR_H / 2, BAR_H / 2)

	local fill_w = math.floor(bar_w * bar_fill)
	if fill_w > 0 then
		if     inf.seeking then love.graphics.setColor(0.45, 0.75, 0.95, 0.8)
		elseif past_loop   then love.graphics.setColor(1.0, 0.65, 0.0)
		else                    love.graphics.setColor(0.20, 0.70, 0.32) end
		love.graphics.rectangle("line", bar_x, bar_y, fill_w, BAR_H, BAR_H / 2, BAR_H / 2)
	end

	if loop_frac then
		local lx = bar_x + math.floor(bar_w * loop_frac)
		love.graphics.setColor(0.95, 0.70, 0.25, 0.95)
		love.graphics.rectangle("fill", lx, bar_y - 2, 3, BAR_H + 4, 1, 1)
	end

	local elapsed_str  = _fmt_time(pos_s / _sample_rate)
	local duration_str = _fmt_time(inf.duration_sec)
	love.graphics.setFont(_fonts.sm)
	love.graphics.setColor(0.65, 0.65, 0.80)
	love.graphics.print(elapsed_str, bar_x, bar_y + BAR_H + 8)
	love.graphics.print(duration_str, W - PAD - _fonts.sm:getWidth(duration_str), bar_y + BAR_H + 8)

	local wave_top = y + 10
	local avail_h  = (bar_y - 12) - wave_top
	if avail_h < 30 then return end

	local avail_w = W - PAD * 2
	local waves = p:waveforms() or {}
	local nr    = 0
	for _, group in ipairs(waves) do
		nr = nr + 1
		_rows[nr] = {
			group     = group,
			label     = group.label or group.id,
			clock     = inf.clocks and inf.clocks[group.id .. "_clock"] or nil,
			hue_start = 0,
		}
	end
	if nr == 0 then return end

	local total_ch = 0
	for i = 1, nr do total_ch = total_ch + #_rows[i].group.labels end
	local hue_step = total_ch > 1 and (1 / total_ch) or 0
	local ch_count = 0
	for i = 1, nr do
		_rows[i].hue_start = BASE_HUE + ch_count * hue_step
		ch_count = ch_count + #_rows[i].group.labels
	end

	local label_h = _fonts.sm:getHeight()
	local cell_h  = math.max(20, math.floor((avail_h - nr * (label_h * 2 + 10)) / nr))
	local wy      = wave_top
	for i = 1, nr do
		wy = _wave_row(_rows[i].group, _rows[i].label, _rows[i].clock, _rows[i].hue_start, hue_step, PAD, wy, avail_w, cell_h)
	end
end

return player_ui
