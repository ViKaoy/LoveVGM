local Player = require("vgm.player")
local ui     = require("ui")

local player    = nil
local err_msg   = nil
local fonts     = {}

local SAMPLE_RATE = 44100
local SEEK_STEP   = 5 * SAMPLE_RATE

local file_tree     = {}
local flat_tree     = {}
local MENU_WIDTH    = 0
local menu_resizing = false
local active_path   = nil

local MENU_MIN_W = 120
local MENU_MAX_W = 600

local function decompress_if_vgz(data)
	if data:byte(1) == 0x1F and data:byte(2) == 0x8B then
		return love.data.decompress("string", "gzip", data)
	end
	return data
end

local function load_vgm_from_string(data, label)
	err_msg = nil
	local ok, result = pcall(function()
		return Player.new(decompress_if_vgz(data))
	end)
	if ok then
		if player then
			player:destroy()
			player = nil
			collectgarbage()
		end
		player      = result
		active_path = label
		player:play()
	else
		err_msg     = tostring(result)
		player      = nil
		active_path = nil
	end
end

local function load_vgm_from_path(path)
	local data, err = love.filesystem.read(path)
	if not data then
		err_msg = "Could not read file: " .. tostring(err)
		return
	end
	load_vgm_from_string(data, path)
end

local function build_tree(path)
	local items = love.filesystem.getDirectoryItems(path)
	local nodes = {}
	for _, item in ipairs(items) do
		local full_path = path == "" and item or (path .. "/" .. item)
		local info      = love.filesystem.getInfo(full_path)
		if info then
			if info.type == "directory" then
				table.insert(nodes, { type = "dir", name = item, path = full_path, open = false, children = nil })
			elseif info.type == "file" and (item:match("%.vgm$") or item:match("%.vgz$")) then
				table.insert(nodes, { type = "file", name = item, path = full_path })
			end
		end
	end
	table.sort(nodes, function(a, b)
		if a.type == b.type then return a.name:lower() < b.name:lower() end
		return a.type == "dir"
	end)
	return nodes
end

local function flatten_tree(nodes, depth)
	for _, node in ipairs(nodes) do
		node.depth = depth
		table.insert(flat_tree, node)
		if node.type == "dir" and node.open and node.children then
			flatten_tree(node.children, depth + 1)
		end
	end
end

local function refresh_flat_tree()
	flat_tree = {}
	flatten_tree(file_tree, 0)
end

function love.load()
	love.window.setTitle("VGM Player")
	love.window.setMode(1280, 680, { minwidth = 600, minheight = 300, resizable = true })
	fonts.sm = love.graphics.newFont(11, "light")
	fonts.md = love.graphics.newFont(14, "light")
	fonts.lg = love.graphics.newFont(21, "light")
	for _, f in pairs(fonts) do f:setFilter("nearest", "nearest") end
	love.graphics.setFont(fonts.md)
	ui.init(fonts, SAMPLE_RATE)

	local info = love.filesystem.getInfo("files")
	if info and info.type == "directory" then
		MENU_WIDTH = 280
		file_tree  = build_tree("files")
		refresh_flat_tree()
	end
end

function love.update(dt)
	if player then player:update(dt) end
end

function love.draw()
	local BG = ui.theme.BG
	love.graphics.setBackgroundColor(unpack(BG))
	love.graphics.clear(unpack(BG))
	love.graphics.setLineStyle("smooth")
	love.graphics.setLineWidth(0.5)

	local W = love.graphics.getWidth()
	local H = love.graphics.getHeight()

	ui.drawNowPlaying(player, active_path, W)

	love.graphics.push()
	love.graphics.translate(MENU_WIDTH, ui.theme.NP_HEIGHT)

	local P_W = W - MENU_WIDTH
	local P_H = H - ui.theme.NP_HEIGHT

	if player then
		ui.drawPlayer(player, P_W, P_H)
	elseif err_msg then
		love.graphics.setFont(fonts.md)
		love.graphics.setColor(1, 0.3, 0.3)
		love.graphics.printf("error loading VGM:\n\n" .. err_msg, 40, 40, P_W - 80)
	end

	love.graphics.pop()

	if MENU_WIDTH > 0 then
		ui.drawMenu(flat_tree, active_path, MENU_WIDTH, menu_resizing)
		if math.abs(love.mouse.getX() - MENU_WIDTH) <= 4 or menu_resizing then
			love.mouse.setCursor(love.mouse.getSystemCursor("sizewe"))
		else
			love.mouse.setCursor()
		end
	end
end

function love.mousepressed(x, y, button)
	if button ~= 1 then return end
	if MENU_WIDTH == 0 then return end

	local result = ui.menuPressed(x, y, flat_tree, MENU_WIDTH, function(node)
		if node.type == "dir" then
			node.open = not node.open
			if node.open and not node.children then
				node.children = build_tree(node.path)
			end
			refresh_flat_tree()
		elseif node.type == "file" then
			load_vgm_from_path(node.path)
		end
	end)

	if result == "resize" then
		menu_resizing = true
	end
end

function love.mousereleased(x, y, button)
	if button == 1 then
		menu_resizing = false
		ui.menuReleased()
	end
end

function love.mousemoved(x, y, dx, dy)
	if menu_resizing then
		MENU_WIDTH = math.max(MENU_MIN_W, math.min(x, MENU_MAX_W))
		return
	end
	ui.menuMoved(y, flat_tree, MENU_WIDTH)
end

function love.wheelmoved(x, y)
	if MENU_WIDTH > 0 then
		local mx, my = love.mouse.getPosition()
		ui.menuWheel(y, mx, my, flat_tree, MENU_WIDTH)
	end
end

function love.filedropped(file)
	local ok, data = pcall(function()
		file:open("r")
		local d = file:read()
		file:close()
		return d
	end)
	if not ok then
		err_msg = "Could not read dropped file: " .. tostring(data)
		player  = nil
		return
	end
	load_vgm_from_string(data, file:getFilename())
end

function love.keypressed(key)
	if key == "escape" then love.event.quit() end
	if key == "r" and DEV_AUTOLOAD then load_vgm_from_path(DEV_AUTOLOAD) end

	if not player then return end

	if key == "space" then
		if player._paused then
			player:play()
		elseif player._playing then
			player:pause()
		end
	end

	if key == "left" then
		player:seek(math.max(0, player:tell() - SEEK_STEP))
	end
	if key == "right" then
		player:seek(math.min(player:tell() + SEEK_STEP, player.header.total_samples))
	end

	if key == "l" and player.header.loop_offset ~= 0 and player.header.loop_samples > 0 then
		local ls = player.header.total_samples - player.header.loop_samples
		if ls > 0 then player:seek(ls) end
	end

	if key == "home" or key == "0" then
		player:stop()
		player:play()
	end
end
