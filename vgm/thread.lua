require "love.sound"
require "love.timer"

local ffi = require("ffi")
ffi.cdef[[ typedef int16_t i16; ]]

local SAMPLE_RATE  = 44100
local CHUNK_FRAMES = 2048
local LPF_ALPHA    = (2 * math.pi * 3390) / (2 * math.pi * 3390 + 44100)
local OUTPUT_GAIN  = 1.5

local instance_id = ...
local cmd_channel  = love.thread.getChannel("vgm_cmd_"  .. instance_id)
local data_channel = love.thread.getChannel("vgm_data_" .. instance_id)

local init = cmd_channel:demand()
local vgm_data, seek_samples, looping_init, current_gen
if type(init) == "table" then
	vgm_data     = init.data
	seek_samples = init.seek_samples or 0
	looping_init = init.looping ~= false
	current_gen  = init.gen or 0
else
	vgm_data     = init
	seek_samples = 0
	looping_init = true
	current_gen  = 0
end

local Parser   = require("vgm.parser")
local Commands = require("vgm.commands")
local Registry = require("vgm.registry")

local parser   = Parser.new(vgm_data)
local hdr      = parser:parse_header()
local registry = Registry.new(hdr)
local cbs      = registry:get_cbs()

local finished, loop_count, pending_wait, lpf_l, lpf_r = false, 0, 0, 0, 0
local commands

local function set_base_cbs()
	cbs.on_loop = function()
		loop_count = loop_count + 1
	end
	cbs.on_end = function()
		finished = true
	end
	cbs.on_wait = function(n)
		pending_wait = pending_wait + n
	end
end

set_base_cbs()

local buf_size    = CHUNK_FRAMES * 2
local mix_buf     = ffi.new("i16[?]", buf_size)
local chip_bufs   = {}
local render_list = registry:render_list()

for _, entry in ipairs(render_list) do
	chip_bufs[entry.id] = ffi.new("i16[?]", buf_size)
end

local function mix(buf_pos, n)
	if n <= 0 then return end
	for _, entry in ipairs(render_list) do
		if entry.render then
			entry.render(entry.chip, chip_bufs[entry.id], buf_pos, n)
		end
	end
	for i = 0, n - 1 do
		local li = (buf_pos + i) * 2
		local ri = li + 1
		local sl = 0
		local sr = 0
		for _, entry in ipairs(render_list) do
			local buf = chip_bufs[entry.id]
			sl = sl + buf[li] * entry.gain
			sr = sr + buf[ri] * entry.gain
		end
		lpf_l = lpf_l + LPF_ALPHA * (sl - lpf_l)
		lpf_r = lpf_r + LPF_ALPHA * (sr - lpf_r)
		sl = math.floor(lpf_l * OUTPUT_GAIN)
		sr = math.floor(lpf_r * OUTPUT_GAIN)
		if sl >  32767 then sl =  32767 end
		if sl < -32768 then sl = -32768 end
		if sr >  32767 then sr =  32767 end
		if sr < -32768 then sr = -32768 end
		mix_buf[li] = sl
		mix_buf[ri] = sr
	end
end

local function do_seek(target_sample, gen)
	registry:reset_chips()
	render_list = registry:render_list()

	finished     = false
	pending_wait = 0
	lpf_l        = 0
	lpf_r        = 0
	loop_count   = 0
	current_gen  = gen

	parser:seek(hdr.data_offset)
	commands = Commands.new(parser, hdr, cbs)
	commands.looping = looping_init

	set_base_cbs()

	if target_sample <= 0 then return end

	local consumed = 0
	local ff_done  = false

	cbs.on_wait = function(n)
		consumed = consumed + n
		if consumed >= target_sample then ff_done = true end
	end
	cbs.on_end = function()
		ff_done  = true
		finished = true
	end
	cbs.on_loop = function()
		loop_count = loop_count + 1
	end

	local steps = 0
	while not ff_done and not commands.done do
		commands:step()
		steps = steps + 1
		if steps >= 4096 then
			steps = 0
			local msg = cmd_channel:pop()
			if msg == "stop" then
				finished = true
				break
			elseif type(msg) == "table" and msg.cmd == "seek" then
				do_seek(msg.sample, msg.gen)
				return
			end
		end
	end

	if consumed > target_sample then
		pending_wait = consumed - target_sample
	end

	set_base_cbs()
end

parser:seek(hdr.data_offset)
commands = Commands.new(parser, hdr, cbs)
commands.looping = looping_init

if seek_samples > 0 then
	do_seek(seek_samples, current_gen)
end

local function render_chunk()
	local total   = CHUNK_FRAMES
	local buf_pos = 0

	if pending_wait > 0 then
		local n = math.min(pending_wait, total)
		mix(buf_pos, n)
		buf_pos      = buf_pos + n
		pending_wait = pending_wait - n
	end

	local orig_wait = cbs.on_wait
	cbs.on_wait = function(wait_samples)
		-- if orig_wait then orig_wait(wait_samples) end
		local remaining = wait_samples
		while remaining > 0 and buf_pos < total do
			local n   = math.min(remaining, total - buf_pos)
			mix(buf_pos, n)
			buf_pos   = buf_pos + n
			remaining = remaining - n
		end
		pending_wait = pending_wait + remaining
	end

	while buf_pos < total and not finished do
		commands:step()
	end

	cbs.on_wait = orig_wait

	if buf_pos < total then
		ffi.fill(mix_buf + buf_pos * 2, (total - buf_pos) * 4, 0)
	end

	local sd = love.sound.newSoundData(CHUNK_FRAMES, SAMPLE_RATE, 16, 2)
	ffi.copy(sd:getFFIPointer(), mix_buf, CHUNK_FRAMES * 4)
	return sd
end

local function poll_commands()
	while true do
		local msg = cmd_channel:pop()
		if msg == nil then return false end
		if msg == "stop" then return true end
		if type(msg) == "table" then
			if msg.cmd == "set_loop" then
				commands.looping = msg.value
			elseif msg.cmd == "seek" then
				do_seek(msg.sample, msg.gen)
			end
		end
	end
end

local MAX_QUEUED = 8
while not finished do
	if poll_commands() then break end

	while data_channel:getCount() >= MAX_QUEUED do
		if poll_commands() then finished = true; break end
		love.timer.sleep(0.005)
	end
	if finished then break end

	data_channel:push({
		sd   = render_chunk(),
		wave = registry:waveform_snapshot(),
		gen  = current_gen,
	})
end

collectgarbage("collect")
data_channel:push("done")
