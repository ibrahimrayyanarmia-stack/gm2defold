-- gm/audio.lua : GameMaker audio_* functions on top of Defold sound components.
-- Each GameMaker sound is a sound component "main:/audio#<name>". Looping is emulated by
-- replaying the sound when it finishes. Missing sounds (e.g. unconverted mp3) are silently ignored.

local A = {}
local meta_sounds = {}
local urls = {}
local playing = {}     -- name -> {count = n, loop = bool}
local handles = {}     -- handle -> {name=, play_id=, loop=}
local next_handle = 1
local gains = {}       -- name -> current gain (0..1)
local fades = {}       -- name -> {from, to, t, dur}
local master = 1

local function url_of(name)
	if type(name) == "number" then
		local h = handles[name]
		name = h and h.name
	end
	if not name then return nil end
	local u = urls[name]
	if u == nil then
		local m = meta_sounds[name]
		if m and not m.missing then u = msg.url("main:/audio#" .. name) else u = false end
		urls[name] = u
	end
	return u or nil, name
end

function A.init(meta)
	meta_sounds = meta.sounds or {}
end

local function base_gain(name)
	local m = meta_sounds[name]
	return (m and m.volume or 1) * master
end

local function start(name, loop, gain, pitch, offset)
	local u = url_of(name)
	if not u then return -1 end
	local h = next_handle
	next_handle = next_handle + 1
	local rec = {name = name, loop = loop, gain = gain, pitch = pitch}
	handles[h] = rec
	local p = playing[name]
	if not p then p = {count = 0} playing[name] = p end
	p.count = p.count + 1
	-- GameMaker gains belong to the playing instance: a new play starts at its own gain. Defold can
	-- only change a component's gain after the voice started, so the instance gain is kept as the
	-- component gain (gains[name]) and the voice plays at the sound's base volume. This way
	-- audio_sound_gain(handle, g) works even when the sound was started at gain 0.
	gains[name] = gain or 1
	fades[name] = nil
	do local uu = url_of(name) if uu then sound.set_gain(uu, gains[name]) end end
	local function play()
		local props = {gain = base_gain(name), speed = pitch or 1}
		if offset and offset > 0 then props.start_time = offset offset = nil end
		rec.play_id = sound.play(u, props, function(self, message_id, message, sender)
			if message_id == hash("sound_done") and rec.loop and not rec.stopped then
				play()
			else
				if not rec.finished then
					rec.finished = true
					p.count = p.count - 1
					handles[h] = nil
				end
			end
		end)
	end
	play()
	return h
end

function audio_play_sound(snd, prio, loop, gain, offset, pitch)
	return start(snd, loop, gain, pitch, offset)
end
function audio_play_sound_at(snd, x, y, z, falloff_ref, falloff_max, falloff_factor, loop, prio, gain, offset, pitch)
	return start(snd, loop, gain, pitch, offset)
end
function audio_play_sound_on(emitter, snd, loop, prio, gain, offset, pitch)
	return start(snd, loop, gain, pitch, offset)
end

local function stop_handle(h, rec)
	rec.stopped = true
	local u = url_of(rec.name)
	if u and rec.play_id then sound.stop(u, {play_id = rec.play_id}) end
	if not rec.finished then
		rec.finished = true
		local p = playing[rec.name]
		if p then p.count = p.count - 1 end
	end
	handles[h] = nil
end

function audio_stop_sound(snd)
	if type(snd) == "number" then
		local rec = handles[snd]
		if rec then stop_handle(snd, rec) end
		return
	end
	for h, rec in pairs(handles) do
		if rec.name == snd then stop_handle(h, rec) end
	end
	local u = url_of(snd)
	if u then sound.stop(u) end
	if playing[snd] then playing[snd].count = 0 end
end

function audio_stop_all()
	for h, rec in pairs(handles) do stop_handle(h, rec) end
	for name, u in pairs(urls) do if u then sound.stop(u) end end
	for _, p in pairs(playing) do p.count = 0 end
end

function audio_is_playing(snd)
	if type(snd) == "number" then
		local rec = handles[snd]
		return rec ~= nil and not rec.finished
	end
	local p = playing[snd]
	return p ~= nil and p.count > 0
end
function audio_exists(snd) return snd ~= nil and meta_sounds[snd] ~= nil end

function audio_pause_sound(snd)
	local u = url_of(snd)
	if u then sound.pause(u, true) end
end
function audio_resume_sound(snd)
	local u = url_of(snd)
	if u then sound.pause(u, false) end
end
function audio_pause_all() for _, u in pairs(urls) do if u then sound.pause(u, true) end end end
function audio_resume_all() for _, u in pairs(urls) do if u then sound.pause(u, false) end end end

local function apply_gain(name)
	local u = url_of(name)
	if u then sound.set_gain(u, (gains[name] or 1)) end
end

-- audio_sound_gain(sound_or_handle, gain, time_ms)
function audio_sound_gain(snd, gain, ms)
	local _, name = url_of(snd)
	if not name then name = snd end
	if type(name) ~= "string" then return end
	if not ms or ms <= 0 then
		gains[name] = gain
		fades[name] = nil
		apply_gain(name)
	else
		fades[name] = {from = gains[name] or 1, to = gain, t = 0, dur = ms / 1000}
	end
end
function audio_sound_get_gain(snd)
	local _, name = url_of(snd)
	return gains[name or snd] or 1
end
function audio_sound_pitch(snd, pitch)
	local u = url_of(snd)
	if u then go.set(u, "speed", pitch) end
end
function audio_sound_length(snd)
	local _, name = url_of(snd)
	local m = meta_sounds[name or snd]
	return m and m.duration or 0
end
function audio_master_gain(g)
	master = g
	sound.set_group_gain("master", g)
end
function audio_set_master_gain(listener, g) audio_master_gain(g) end
function audio_group_set_gain(group, g, ms) end
function audio_group_load(group) return true end
function audio_group_is_loaded(group) return true end
function audio_falloff_set_model() end
function audio_listener_position() end
function audio_emitter_create() return {} end
function audio_emitter_position() end
function audio_emitter_gain() end
function audio_emitter_free() end

function A.update(dt)
	for name, f in pairs(fades) do
		f.t = f.t + dt
		local k = math.min(1, f.t / f.dur)
		gains[name] = f.from + (f.to - f.from) * k
		apply_gain(name)
		if k >= 1 then fades[name] = nil end
	end
end

return A
