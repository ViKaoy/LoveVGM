local nowplaying = {}
local theme      = require("ui.theme")

local PAD  = 24
local _ivs = { "B", "KB", "MB", "GB" }

local function _bytes(x, i)
	i = i or 1
	while x >= 1024 and i < 4 do x, i = x / 1024, i + 1 end
	return ("%.1f %s"):format(x, _ivs[i])
end

local _fonts

function nowplaying.init(fonts)
	_fonts = fonts
end

function nowplaying.draw(player, active_path, W)
	local bx = theme.MM
	local by = theme.MM
	local bw = W - 2 * theme.MM
	local bh = theme.NP_HEIGHT - 2 * theme.MM

	love.graphics.setColor(unpack(theme.MENU_BG))
	love.graphics.rectangle("fill", bx, by, bw, bh, 8, 8)
	love.graphics.setColor(unpack(theme.DIVIDER))
	love.graphics.rectangle("fill", bx, by + bh - 1, bw, 1)

	local fh = _fonts.sm:getHeight()
	local fy = by + math.floor(bh / 2) - math.floor(fh / 2)

	love.graphics.setFont(_fonts.sm)
	local stats   = love.timer.getFPS() .. " fps  ·  " .. _bytes(collectgarbage("count"), 2)
	local stats_w = _fonts.sm:getWidth(stats)
	love.graphics.setColor(0.30, 0.30, 0.45)
	love.graphics.print(stats, bx + bw - PAD - stats_w, fy)

	if player then
		local inf = player:info()
		local gd3 = inf.gd3

		local np_lbl = "NOW PLAYING"
		local np_w   = _fonts.sm:getWidth(np_lbl)
		love.graphics.setColor(0.35, 0.35, 0.52)
		love.graphics.print(np_lbl, bx + PAD, fy)

		local track = (gd3 and gd3.track ~= "") and gd3.track
		           or ((active_path or ""):match("[^/\\]+$") or "?")
		love.graphics.setColor(0.93, 0.93, 1.00)
		love.graphics.print(track, bx + PAD + np_w + 12, fy)

		local badge, br, bg2, bb
		if     inf.seeking then badge = "SEEKING..."; br, bg2, bb = 0.45, 0.75, 0.95
		elseif inf.paused  then badge = "PAUSED";     br, bg2, bb = 0.90, 0.75, 0.25 end

		if badge then
			love.graphics.setColor(br, bg2, bb)
			love.graphics.print(badge, bx + bw - PAD - stats_w - _fonts.sm:getWidth(badge) - 20, fy)
		end
	else
		love.graphics.setColor(0.40, 0.40, 0.55)
		love.graphics.printf("Drop a file or select from menu", bx, fy, bw, "center")
	end
end

return nowplaying
