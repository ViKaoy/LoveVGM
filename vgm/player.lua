local bit = require("bit")
local Parser = require("vgm.parser")

local Player = {}
Player.__index = Player

local SAMPLE_RATE  = 44100
local CHUNK_FRAMES = 2048
local QUEUE_AHEAD  = 4
local BUFFERCOUNT  = 8

local _next_id = 0

function Player.new(data)
	local self = setmetatable({}, Player)

	self._raw_data = data

	local p     = Parser.new(data)
	self.header = p:parse_header()
	self.gd3    = p:parse_gd3(self.header)
	_next_id    = _next_id + 1
	self._id    = tostring(_next_id)

	self._cmd_ch  = love.thread.getChannel("vgm_cmd_"  .. self._id)
	self._data_ch = love.thread.getChannel("vgm_data_" .. self._id)
	self._cmd_ch:clear()
	self._data_ch:clear()

	self.source = love.audio.newQueueableSource(SAMPLE_RATE, 16, 2, BUFFERCOUNT)

	self.finished        = false
	self.loop_count      = 0
	self._samples_queued = 0
	self._seek_sample    = 0
	self._thread_done    = false
	self._playing        = false
	self._paused         = false
	self._seeking        = false
	self._looping        = true
	self._thread         = nil
	self._gen            = 0 -- chunk generation; bumped on each seek

	self._wave_deque = {}
	self:_start_thread()

	return self
end

function Player:_start_thread()
	if self._thread then
		self._thread:wait()
		self._thread = nil
	end
	self._thread = love.thread.newThread("vgm/thread.lua")
	self._thread:start(self._id)
	self._cmd_ch:push({
		data         = self._raw_data,
		seek_samples = self._seek_sample,
		looping      = self._looping,
		gen          = self._gen,
	})
end

function Player:_reset_thread(seek_sample)
	if self._thread then
		self._cmd_ch:push("stop")
		self._thread:wait()
		self._thread = nil
	end
	self._cmd_ch:clear()
	self._data_ch:clear()

	self.source:stop()
	self.source = love.audio.newQueueableSource(SAMPLE_RATE, 16, 2, BUFFERCOUNT)

	self._samples_queued = 0
	self._seek_sample    = math.max(0, seek_sample or 0)
	self._wave_deque     = {}
	self._thread_done    = false
	self.finished        = false

	self:_start_thread()
end

function Player:play(opts)
	opts = opts or {}

	if self._paused then
		self.source:play()
		self._paused  = false
		self._seeking = false
		return
	end

	if self._playing then return end

	if opts.loop_start
		and self.header.loop_offset ~= 0
		and self.header.loop_samples > 0
	then
		local ls = self.header.total_samples - self.header.loop_samples
		if ls > 0 then
			self:_reset_thread(ls)
		end
	end

	if not self._seeking then
		while self._data_ch:getCount() < QUEUE_AHEAD and not self._thread_done do
			love.timer.sleep(0.001)
			if self._data_ch:peek() == "done" then break end
		end
		self:_drain_queue()
		self.source:play()
	end

	self._playing = true
end

function Player:pause()
	if not self._playing or self._paused then return end
	self.source:pause()
	self._paused = true
end

function Player:stop()
	self._playing = false
	self._paused  = false
	self._seeking = false
	self:_reset_thread(0)
end

function Player:seek(sample)
	local was_playing = self._playing and not self._paused
	self._playing = false
	self._paused  = false
	self._seeking = true

	if self._thread_done or not self._thread then
		self:_reset_thread(sample)
	else
		self.source:stop()
		self.source = love.audio.newQueueableSource(SAMPLE_RATE, 16, 2, BUFFERCOUNT)

		self._samples_queued = 0
		self._seek_sample    = math.max(0, sample)
		self._wave_deque     = {}
		self._gen            = self._gen + 1

		self._cmd_ch:push({
			cmd    = "seek",
			sample = self._seek_sample,
			gen    = self._gen,
		})
	end

	if was_playing then self._playing = true end
end

function Player:tell()
	local filled = BUFFERCOUNT - self.source:getFreeBufferCount()
	local played = math.max(0, self._samples_queued - filled * CHUNK_FRAMES)
	local pos    = self._seek_sample + played
	local total  = self.header.total_samples
	if total and total > 0 and pos >= total then
		local loop_start = (self.header.loop_samples and self.header.loop_samples > 0)
			  and (total - self.header.loop_samples) or 0
		pos = loop_start + (pos - loop_start) % (total - loop_start)
	end
	return pos
end

function Player:setLooping(value)
	self._looping = value
	self._cmd_ch:push({ cmd = "set_loop", value = value })
end

function Player:destroy()
	self._cmd_ch:push("stop")
	self.source:stop()
	self._playing = false
	self._paused  = false
	self._seeking = false

	if self._thread then
		self._thread:wait()
		self._thread = nil
	end
	self._cmd_ch:clear()
	self._data_ch:clear()
	self._wave_deque  = {}
	self._thread_done = true
	self.finished     = true
end

function Player:update(dt)
	if self.finished then return end

	if self._thread then
		local err = self._thread:getError()
		if err then
			print("[player] thread error: " .. err)
			self.finished     = true
			self._thread_done = true
			return
		end
	end

	self:_drain_queue()
	self:_sync_wave_deque()

	if self._seeking and self._samples_queued > 0 then
		self.source:play()
		self._seeking = false
	end

	if self._playing and not self._paused and not self._seeking
		and not self.source:isPlaying()
		and not self.finished
	then
		self.source:play()
	end
end

function Player:_drain_queue()
	local free = self.source:getFreeBufferCount()
	while free > 0 do
		local v = self._data_ch:pop()
		if v == nil then break end

		if v == "done" then
			if self._seeking then
				self._seeking     = false
				self._thread_done = false
				self:_reset_thread(self._seek_sample)
				if self._playing then self:play() end
			else
				self._thread_done = true
				self.finished     = true
			end
			break
		end

		if type(v) == "string" and v:sub(1, 6) == "error:" then
			print("[player] render error: " .. v:sub(7))
			self._thread_done = true
			self.finished     = true
			break
		end

		if not (type(v) == "table" and v.gen ~= self._gen) then
			self.source:queue(v.sd)
			table.insert(self._wave_deque, v.wave)
			self._samples_queued = self._samples_queued + CHUNK_FRAMES
			free = free - 1
		end
	end
end

function Player:_sync_wave_deque()
	local chunks_in_buf = BUFFERCOUNT - self.source:getFreeBufferCount()
	while #self._wave_deque > chunks_in_buf and #self._wave_deque > 1 do
		table.remove(self._wave_deque, 1)
	end
end

function Player:info()
	local hdr    = self.header
	local clocks = {}
	for k, v in pairs(hdr) do
		if type(k) == "string"
			and k:sub(-6) == "_clock"
			and type(v) == "number"
			and v ~= 0
		then
			clocks[k] = bit.band(v, 0x3FFFFFFF)
		end
	end
	return {
		gd3              = self.gd3,
		version_str      = hdr.version_str,
		duration_sec     = hdr.duration_sec,
		total_samples    = hdr.total_samples,
		loop_offset      = hdr.loop_offset ~= 0 and hdr.loop_offset or nil,
		clocks           = clocks,
		finished         = self.finished,
		loop_count       = self.loop_count,
		samples_rendered = self._samples_queued,
		looping          = self._looping,
		paused           = self._paused,
		seeking          = self._seeking,
	}
end

function Player:waveforms()
	return self._wave_deque[1]
end

return Player
