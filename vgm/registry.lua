local Registry = {}
Registry.__index = Registry

local CHIP_MODULES = {
	"vgm.chips.ym2612",
	"vgm.chips.sn76489",
	"vgm.chips.rf5c164",
	"vgm.chips.pwm",
}

local function _register_chip(self, desc, clock, hdr)
	local instance = desc.new(clock, hdr)
	self._chips[desc.id] = instance

	if desc.commands then
		for cmd, fn in pairs(desc.commands) do
			local chip = instance
			self._cmd_map[cmd] = function(reg, val)
				fn(chip, reg, val)
			end
		end
	end

	if desc.events then
		for ev, fn in pairs(desc.events) do
			if not self._ev_lists[ev] then
				self._ev_lists[ev] = {}
			end
			local chip = instance
			table.insert(self._ev_lists[ev], function(...)
				fn(chip, ...)
			end)
		end
	end

	table.insert(self._render_list, {
		id          = desc.id,
		chip        = instance,
		gain        = desc.gain or 1.0,
		render      = desc.render,
		wave_active = desc.wave_active,
		wave_extra  = desc.wave_extra,
		desc        = desc,
	})
end

function Registry.new(hdr)
	local self = setmetatable({}, Registry)
	self._chips       = {}
	self._render_list = {}
	self._cmd_map     = {}
	self._ev_lists    = {}
	self._cbs         = {}
	self._hdr         = hdr

	for _, path in ipairs(CHIP_MODULES) do
		local ok, mod = pcall(require, path)
		if ok and mod and mod.descriptor then
			local desc   = mod.descriptor
			local clock  = 0
			local active = true
			if desc.clock_field then
				clock  = hdr[desc.clock_field] or 0
				active = clock ~= 0
			end
			if active then
				_register_chip(self, desc, clock, hdr)
			end
		elseif not ok then
			print(string.format("[registry] could not load %s: %s", path, tostring(mod)))
		end
	end

	self:_build_cbs()
	return self
end

function Registry:get(id)
	return self._chips[id]
end

function Registry:render_list()
	return self._render_list
end

function Registry:get_cbs()
	return self._cbs
end

function Registry:_build_cbs()
	local cbs = self._cbs
	for k in pairs(cbs) do cbs[k] = nil end

	local cmd_map  = self._cmd_map
	local ev_lists = self._ev_lists

	cbs.on_chip_write = function(name, reg, val)
		local h = cmd_map[name]
		if h then h(reg, val) end
	end

	for ev, list in pairs(ev_lists) do
		if ev ~= "on_dac_bank_write" then
			local ls = list
			cbs[ev] = function(...)
				for _, h in ipairs(ls) do h(...) end
			end
		end
	end

	local dab = ev_lists["on_dac_bank_write"]
	cbs.on_dac_bank_write = function(wait_n)
		if dab then
			for _, h in ipairs(dab) do h(wait_n) end
		end
		if wait_n > 0 and cbs.on_wait then
			cbs.on_wait(wait_n)
		end
	end
end

function Registry:reset_chips()
	local hdr      = self._hdr
	self._chips    = {}
	self._cmd_map  = {}
	self._ev_lists = {}

	local new_list = {}
	for _, old in ipairs(self._render_list) do
		local desc  = old.desc
		local clock = desc.clock_field and (hdr[desc.clock_field] or 0) or 0
		local instance = desc.new(clock, hdr)
		self._chips[desc.id] = instance

		if desc.commands then
			for cmd, fn in pairs(desc.commands) do
				local chip = instance
				self._cmd_map[cmd] = function(reg, val)
					fn(chip, reg, val)
				end
			end
		end

		if desc.events then
			for ev, fn in pairs(desc.events) do
				if not self._ev_lists[ev] then
					self._ev_lists[ev] = {}
				end
				local chip = instance
				table.insert(self._ev_lists[ev], function(...)
					fn(chip, ...)
				end)
			end
		end

		table.insert(new_list, {
			id          = desc.id,
			chip        = instance,
			gain        = desc.gain or 1.0,
			render      = desc.render,
			wave_active = desc.wave_active,
			wave_extra  = desc.wave_extra,
			desc        = desc,
		})
	end

	self._render_list = new_list
	self:_build_cbs()
end

function Registry:waveform_snapshot()
	local snap = {}
	for _, entry in ipairs(self._render_list) do
		local chip = entry.chip
		if chip.wave_bufs and chip.wave_labels then
			local active = true
			if entry.wave_active then
				active = entry.wave_active(chip)
			end
			if active then
				local bufs = {}
				for i, src in ipairs(chip.wave_bufs) do
					local dst = {}
					for j = 1, #src do dst[j] = src[j] end
					bufs[i] = dst
				end
				local s = {
					id       = entry.id,
					label    = entry.id,
					bufs     = bufs,
					wave_pos = chip.wave_pos or 0,
					labels   = chip.wave_labels,
				}
				if entry.wave_extra then
					local extra = entry.wave_extra(chip)
					for k, v in pairs(extra) do s[k] = v end
				end
				snap[#snap + 1] = s
			end
		end
	end
	return snap
end

return Registry
