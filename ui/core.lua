local core   = {}
local _fonts = {}

function core.init(fonts)
	_fonts = fonts
end

function core.font(name)
	return _fonts[name]
end

function core.setFont(name)
	love.graphics.setFont(_fonts[name])
end

function core.setColor(...)
	love.graphics.setColor(...)
end

function core.fontWidth(name, str)
	return _fonts[name]:getWidth(str)
end

function core.drawTextScaled(str, x, y, max_w, align)
	if str == "" then return end
	local f  = love.graphics.getFont()
	local tw = f:getWidth(str)
	local sx = (tw > max_w and max_w > 0) and (max_w / tw) or 1
	love.graphics.push()
	if align == "right" then
		love.graphics.translate(x + max_w, y)
		love.graphics.scale(sx, 1)
		love.graphics.print(str, -tw, 0)
	else
		love.graphics.translate(x, y)
		love.graphics.scale(sx, 1)
		love.graphics.print(str, 0, 0)
	end
	love.graphics.pop()
end

return core
