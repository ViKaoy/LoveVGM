local theme      = require("ui.theme")
local core       = require("ui.core")
local wave       = require("ui.wave")
local menu_mod   = require("ui.menu")
local np_mod     = require("ui.nowplaying")
local player_mod = require("ui.player")

local ui = {}

function ui.init(fonts, sample_rate)
	core.init(fonts)
	menu_mod.init(fonts)
	np_mod.init(fonts)
	player_mod.init(fonts, sample_rate)
end

ui.theme = theme

ui.setFont        = core.setFont
ui.setColor       = core.setColor
ui.fontWidth      = core.fontWidth
ui.font           = core.font
ui.drawTextScaled = core.drawTextScaled

ui.drawWave  = wave.draw
ui.WAVE_SIZE = wave.WAVE_SIZE

ui.drawMenu     = menu_mod.draw
ui.menuPressed  = menu_mod.mousepressed
ui.menuReleased = menu_mod.mousereleased
ui.menuMoved    = menu_mod.mousemoved
ui.menuWheel    = menu_mod.wheelmoved

ui.drawNowPlaying = np_mod.draw
ui.drawPlayer     = player_mod.draw

return ui
