local menu  = {}
local theme = require("ui.theme")

local ITEM_H  = 22
local PAD_Y   = 4
local SB_PADY = 4
local SB_W    = 6
local SB_MRG  = 4

local _fonts
local _scroll      = 0
local _drag        = false
local _drag_y      = 0
local _drag_scroll = 0

local function _panel(mw)
	return theme.MM,
	       theme.NP_HEIGHT + theme.MM,
	       mw - 2 * theme.MM,
	       love.graphics.getHeight() - theme.NP_HEIGHT - 2 * theme.MM
end

function menu.init(fonts)
	_fonts = fonts
end

function menu.draw(flat_tree, active_path, mw, resizing)
	local px, py, pw, ph = _panel(mw)

	love.graphics.setColor(unpack(theme.MENU_BG))
	love.graphics.rectangle("fill", px, py, pw, ph, 8, 8)

	local content_h  = #flat_tree * ITEM_H + PAD_Y * 2
	local max_scroll = math.max(0, content_h - ph)
	_scroll = math.max(0, math.min(_scroll, max_scroll))

	local scrollable = content_h > ph
	local clip_w     = pw - (scrollable and (SB_W + SB_MRG * 2) or 0)

	local sx, sy = love.graphics.transformPoint(px, py)
	love.graphics.setScissor(math.floor(sx), math.floor(sy), pw, ph)
	love.graphics.push()
	love.graphics.translate(px, py - _scroll)

	local mx, my  = love.mouse.getPosition()
	local hover_i = nil
	if mx >= px and mx < px + clip_w and my >= py and my < py + ph and not resizing then
		hover_i = math.floor((my - py + _scroll - PAD_Y) / ITEM_H) + 1
	end

	love.graphics.setFont(_fonts.sm)
	local text_oy = math.floor((ITEM_H - _fonts.sm:getHeight()) / 2)

	for i, node in ipairs(flat_tree) do
		local iy = PAD_Y + (i - 1) * ITEM_H
		if iy + ITEM_H > _scroll and iy < _scroll + ph then
			local active = node.path == active_path
			local rx, rw = 4, clip_w - 8

			if active then
				love.graphics.setColor(0.20, 0.70, 0.32, 0.18)
				love.graphics.rectangle("fill", rx, iy + 1, rw, ITEM_H - 2, 4, 4)
				love.graphics.setColor(0.20, 0.70, 0.32, 0.9)
				love.graphics.rectangle("fill", 0, iy + 3, 3, ITEM_H - 6, 2, 2)
			elseif hover_i == i then
				love.graphics.setColor(1, 1, 1, 0.07)
				love.graphics.rectangle("fill", rx, iy + 1, rw, ITEM_H - 2, 4, 4)
			end

			local tx  = rx + 8 + node.depth * 14
			local tw  = rw - (tx - rx) - 4
			local tsx = love.graphics.transformPoint(tx, iy)
			love.graphics.setScissor(math.floor(tsx), math.floor(sy), math.floor(tw), ph)

			if node.type == "dir" then
				love.graphics.setColor(0.55, 0.65, 0.80)
				love.graphics.print(node.open and "-" or "+", tx, iy + text_oy)
				love.graphics.print(node.name, tx + 12, iy + text_oy)
			else
				love.graphics.setColor(active and 0.9 or 0.72, active and 0.95 or 0.72, active and 0.9 or 0.78)
				love.graphics.print(node.name, tx, iy + text_oy)
			end

			love.graphics.setScissor(math.floor(sx), math.floor(sy), pw, ph)
		end
	end

	love.graphics.pop()
	love.graphics.setScissor()

	if scrollable then
		local tr_h    = ph - SB_PADY * 2
		local thumb_h = math.max(20, tr_h * (ph / content_h))
		local thumb_y = (_scroll / max_scroll) * (tr_h - thumb_h)
		local sb_x    = px + pw - SB_W - SB_MRG
		love.graphics.setColor(1, 1, 1, 0.05)
		love.graphics.rectangle("fill", sb_x, py + SB_PADY, SB_W, tr_h, SB_W / 2, SB_W / 2)
		love.graphics.setColor(1, 1, 1, _drag and 0.4 or 0.2)
		love.graphics.rectangle(_drag and "line" or "fill", sb_x, py + SB_PADY + thumb_y, SB_W, thumb_h, SB_W / 2, SB_W / 2)
	end

	local near = math.abs(love.mouse.getX() - mw) <= 4
	love.graphics.setColor(1, 1, 1, (resizing or near) and 0.55 or 0.18)
	love.graphics.rectangle("fill", mw - 1, theme.NP_HEIGHT, 1, love.graphics.getHeight() - theme.NP_HEIGHT)
end

function menu.mousepressed(x, y, flat_tree, mw, on_node)
	if math.abs(x - mw) <= 4 then return "resize" end
	if x >= mw then return end

	local px, py, pw, ph = _panel(mw)
	if x < px or y < py or y >= py + ph then return end

	local content_h  = #flat_tree * ITEM_H + PAD_Y * 2
	local max_scroll = math.max(0, content_h - ph)

	if max_scroll > 0 then
		local sb_x = px + pw - SB_W - SB_MRG
		if x >= sb_x then
			local tr_h    = ph - SB_PADY * 2
			local thumb_h = math.max(20, tr_h * (ph / content_h))
			local tr_sc   = tr_h - thumb_h
			local thumb_y = py + SB_PADY + (_scroll / max_scroll) * tr_sc
			if y >= thumb_y and y < thumb_y + thumb_h then
				_drag        = true
				_drag_y      = y
				_drag_scroll = _scroll
			else
				local t = ((y - (py + SB_PADY)) - thumb_h / 2) / math.max(1, tr_sc) * max_scroll
				_scroll = math.max(0, math.min(t, max_scroll))
			end
			return "scrollbar"
		end
	end

	local idx  = math.floor(((y - py) + _scroll - PAD_Y) / ITEM_H) + 1
	local node = flat_tree[idx]
	if node and on_node then on_node(node) end
end

function menu.mousereleased()
	_drag = false
end

function menu.mousemoved(y, flat_tree, mw)
	if not _drag then return end
	local px, py, pw, ph = _panel(mw)
	local content_h  = #flat_tree * ITEM_H + PAD_Y * 2
	local max_scroll = math.max(0, content_h - ph)
	local tr_h       = ph - SB_PADY * 2
	local thumb_h    = math.max(20, tr_h * (ph / content_h))
	local tr_sc      = tr_h - thumb_h
	if tr_sc > 0 then
		_scroll = _drag_scroll + (y - _drag_y) * (max_scroll / tr_sc)
		_scroll = math.max(0, math.min(_scroll, max_scroll))
	end
end

function menu.wheelmoved(dy, mx, my, flat_tree, mw)
	local px, py, pw, ph = _panel(mw)
	if mx >= px and mx < px + pw and my >= py and my < py + ph then
		local max_scroll = math.max(0, #flat_tree * ITEM_H + PAD_Y * 2 - ph)
		_scroll = math.max(0, math.min(_scroll - dy * 40, max_scroll))
	end
end

return menu
