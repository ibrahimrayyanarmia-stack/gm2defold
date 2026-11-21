-- gm/gm.lua : a small GameMaker-compatible runtime for Defold.
--
-- Objects:   every GameMaker object becomes a global Lua table (class) named like the object,
--            created from game/meta.lua before game code loads. Parent objects are linked with
--            metatables, so a child inherits its parent's events. Define events as
--               function objPlayer.step(self) ... end
--            event_inherited() is  inherited(objPlayer, "step", self)
-- Instances: plain tables with GameMaker built-in variables (x, y, sprite_index, image_index, ...).
--            Reading self.speed/self.direction/self.bbox_* etc. is computed; writing speed/direction
--            updates hspeed/vspeed like GameMaker.
-- Current instance: functions that implicitly use `self` in GML (place_meeting, instance_destroy(),
--            draw_self(), move_towards_point, ...) use gm.current, which the runtime sets to the
--            instance whose event is running (and to the target inside with_()).

local lib = require "gm.lib"
local D = require "gm.draw"
local A = require "gm.audio"

local gm = {}
_G.gm = gm
local G = _G
local floor, abs, sqrt = math.floor, math.abs, math.sqrt

global = {}           -- GML `global.`
gm.global = global

local META
local OBJ = {}          -- name -> class
local SPR               -- sprite meta
local instances = {}    -- creation order
local by_id = {}
local next_id = 100000
local tick_no = 0
gm.current = nil

-- room state
local room_name = nil
local room_data = nil
local room_layers = {}  -- runtime layers
local pending_room = nil
local pending_restart = false
local pending_end = false
local persistent_rooms = {}

-- ------------------------------------------------------------------ classes
local function make_class(name)
	local c = OBJ[name]
	if c then return c end
	c = {__name = name, __is_object = true}
	OBJ[name] = c
	G[name] = c
	return c
end

local function is_child_of(cls, parent)
	while cls do
		if cls == parent then return true end
		cls = cls.__parent
	end
	return false
end
gm.is_child_of = is_child_of

-- event_inherited():  inherited(objX, "create", self)  -- objX = the object whose event is running
function inherited(cls, ev, self, ...)
	local p = cls.__parent
	while p do
		local f = rawget(p, ev)
		if f then return f(self, ...) end
		p = p.__parent
	end
end
event_inherited = inherited

function object_get_name(cls) return cls and cls.__name or "<undefined>" end
function object_get_parent(cls) return cls.__parent or -100 end
function object_is_ancestor(cls, parent) return cls ~= parent and is_child_of(cls, parent) end
function object_exists(cls) return type(cls) == "table" and rawget(cls, "__is_object") == true end
function object_get_sprite(cls) local m = META.objects[cls.__name] return m and m.sprite end

-- ------------------------------------------------------------------ instance metatable
local getters, setters = {}, {}

local function inst_index(t, k)
	local g = getters[k]
	if g then return g(t) end
	local cls = rawget(t, "object_index")
	if cls then return cls[k] end
	return nil
end
local function inst_newindex(t, k, v)
	local s = setters[k]
	if s then s(t, v) else rawset(t, k, v) end
end
local INST_MT = {__index = inst_index, __newindex = inst_newindex,
	__tostring = function(t) return "<instance " .. tostring(rawget(t, "id")) .. " of " .. tostring(rawget(t, "object_index") and rawget(t, "object_index").__name) .. ">" end}
gm.INST_MT = INST_MT

-- keep direction in sync when hspeed/vspeed are written directly
setters.hspeed = function(t, v)
	rawset(t, "_hs", v)
	local vv = rawget(t, "_vs") or 0
	if v ~= 0 or vv ~= 0 then rawset(t, "_dir", point_direction(0, 0, v, vv)) end
end
setters.vspeed = function(t, v)
	rawset(t, "_vs", v)
	local hh = rawget(t, "_hs") or 0
	if v ~= 0 or hh ~= 0 then rawset(t, "_dir", point_direction(0, 0, hh, v)) end
end
getters.hspeed = function(t) return rawget(t, "_hs") or 0 end
getters.vspeed = function(t) return rawget(t, "_vs") or 0 end
setters.speed = function(t, s)
	local d = rawget(t, "_dir")
	rawset(t, "_hs", lengthdir_x(s, d))
	rawset(t, "_vs", lengthdir_y(s, d))
end
setters.direction = function(t, d)
	d = d % 360
	local h, v = rawget(t, "_hs") or 0, rawget(t, "_vs") or 0
	local s = sqrt(h * h + v * v)
	rawset(t, "_dir", d)
	rawset(t, "_hs", lengthdir_x(s, d))
	rawset(t, "_vs", lengthdir_y(s, d))
end
getters.speed = function(t) local h, v = rawget(t, "_hs") or 0, rawget(t, "_vs") or 0 return sqrt(h * h + v * v) end

-- bounding box (GameMaker style, rectangle masks; rotation uses the rotated AABB)
local function mask_of(t)
	local m = rawget(t, "mask_index")
	if m == nil or m == -1 or m == noone then m = rawget(t, "sprite_index") end
	if m == nil or m == -1 or m == noone then return nil end
	return SPR[m]
end
-- returns l, t, r, b with r/b exclusive, or nil when the instance has no mask
local function rect_at(t, x, y)
	local s = mask_of(t)
	if not s then return nil end
	local bb = s.bbox
	local xs, ys = rawget(t, "image_xscale"), rawget(t, "image_yscale")
	local l = (bb[1] - s.xo) * xs
	local r = (bb[3] + 1 - s.xo) * xs
	local tp = (bb[2] - s.yo) * ys
	local b = (bb[4] + 1 - s.yo) * ys
	if l > r then l, r = r, l end
	if tp > b then tp, b = b, tp end
	local ang = rawget(t, "image_angle")
	if ang ~= 0 then
		local a = math.rad(ang)
		local c, sn = math.cos(a), math.sin(a)
		local xs_, ys_ = {}, {}
		for i, p in ipairs({{l, tp}, {r, tp}, {l, b}, {r, b}}) do
			-- GM rotates counter-clockwise on screen (y down)
			xs_[i] = p[1] * c + p[2] * sn
			ys_[i] = -p[1] * sn + p[2] * c
		end
		l, r = math.min(xs_[1], xs_[2], xs_[3], xs_[4]), math.max(xs_[1], xs_[2], xs_[3], xs_[4])
		tp, b = math.min(ys_[1], ys_[2], ys_[3], ys_[4]), math.max(ys_[1], ys_[2], ys_[3], ys_[4])
	end
	return x + l, y + tp, x + r, y + b
end
gm.rect_at = rect_at
getters.bbox_left = function(t) local l = rect_at(t, rawget(t, "x"), rawget(t, "y")) return l or rawget(t, "x") end
getters.bbox_top = function(t) local _, tp = rect_at(t, rawget(t, "x"), rawget(t, "y")) return tp or rawget(t, "y") end
getters.bbox_right = function(t) local _, _, r = rect_at(t, rawget(t, "x"), rawget(t, "y")) return r and (r - 1) or rawget(t, "x") end
getters.bbox_bottom = function(t) local _, _, _, b = rect_at(t, rawget(t, "x"), rawget(t, "y")) return b and (b - 1) or rawget(t, "y") end
getters.sprite_width = function(t) local s = SPR[rawget(t, "sprite_index")] return s and s.w * rawget(t, "image_xscale") or 0 end
getters.sprite_height = function(t) local s = SPR[rawget(t, "sprite_index")] return s and s.h * rawget(t, "image_yscale") or 0 end
getters.sprite_xoffset = function(t) local s = SPR[rawget(t, "sprite_index")] return s and s.xo or 0 end
getters.sprite_yoffset = function(t) local s = SPR[rawget(t, "sprite_index")] return s and s.yo or 0 end
getters.image_number = function(t) local s = SPR[rawget(t, "sprite_index")] return s and s.n or 0 end
getters.object_name = function(t) return rawget(t, "object_index").__name end

-- ------------------------------------------------------------------ events
local traceback = debug.traceback
local function snapshot(list)
	local c = {}
	for i = 1, #list do c[i] = list[i] end
	return c
end
gm.snapshot = snapshot
local reported = {}
local function report(where, err)
	local key = where .. tostring(err)
	if reported[key] then return end
	reported[key] = true
	print("ERROR in " .. where .. ": " .. tostring(err))
end
gm.report = report
local function call(inst, f, ...)
	local prev = gm.current
	gm.current = inst
	local args = {...}
	local n = select("#", ...)
	local ok, err = xpcall(function() return f(inst, unpack(args, 1, n)) end, traceback)
	gm.current = prev
	if not ok then
		report(tostring(rawget(inst, "object_index") and rawget(inst, "object_index").__name), err)
		if gm.strict then error(err, 0) end
	end
end
gm.call = call

local function fire(inst, ev, ...)
	local f = inst.object_index[ev]
	if f and type(f) == "function" then call(inst, f, ...) return true end
	return false
end
gm.fire = fire

function event_user(n) local s = gm.current if s then fire(s, "user" .. n) end end
function event_perform(kind, n) local s = gm.current if s then fire(s, kind .. (n or "")) end end
function event_perform_object(cls, ev, ...) local f = cls[ev] if f then f(gm.current, ...) end end

-- ------------------------------------------------------------------ instance creation
local layer_by_name = {}

local function new_instance(cls, x, y, depth, vars, layer)
	if type(cls) ~= "table" or not rawget(cls, "__is_object") then error("instance_create: not an object: " .. tostring(cls), 3) end
	local om = META.objects[cls.__name] or {}
	next_id = next_id + 1
	local t = {
		id = next_id, object_index = cls,
		x = x, y = y, xstart = x, ystart = y, xprevious = x, yprevious = y,
		sprite_index = om.sprite, mask_index = om.mask, image_index = 0, image_speed = 1,
		image_xscale = 1, image_yscale = 1, image_angle = 0, image_blend = 16777215, image_alpha = 1,
		visible = om.visible ~= false, persistent = om.persistent == true, solid = om.solid == true,
		depth = depth or 0, layer = layer,
		_hs = 0, _vs = 0, _dir = 0, friction = 0, gravity = 0, gravity_direction = 270,
		alarm = {}, _alive = true, _active = true, _order = next_id,
	}
	for i = 0, 11 do t.alarm[i] = -1 end
	setmetatable(t, INST_MT)
	-- Variable Definitions (parents first, then this object's overrides)
	local chain = {}
	local c = cls
	while c do table.insert(chain, 1, c) c = c.__parent end
	for _, cc in ipairs(chain) do
		local m = META.objects[cc.__name]
		if m then
			for k, v in pairs(m.props or {}) do t[k] = v end
			for k, v in pairs(m.overridden or {}) do t[k] = v end
		end
	end
	if vars then for k, v in pairs(vars) do t[k] = v end end
	instances[#instances + 1] = t
	by_id[t.id] = t
	return t
end

local function layer_depth(layer)
	if type(layer) == "number" then
		for _, L in ipairs(room_layers) do if L.id == layer then return L.depth, L.name end end
		return 0, nil
	end
	local L = layer_by_name[layer]
	if L then return L.depth, L.name end
	return 0, layer
end

function instance_create_depth(x, y, depth, cls, vars)
	local t = new_instance(cls, x, y, depth, vars, nil)
	fire(t, "create")
	return t
end
function instance_create_layer(x, y, layer, cls, vars)
	local d, name = layer_depth(layer)
	local t = new_instance(cls, x, y, d, vars, name)
	fire(t, "create")
	return t
end
function instance_copy(perf)
	local s = gm.current
	local t = new_instance(s.object_index, s.x, s.y, s.depth, nil, s.layer)
	for k, v in pairs(s) do if k ~= "id" and k ~= "_order" then rawset(t, k, v) end end
	t.alarm = {} for i = 0, 11 do t.alarm[i] = s.alarm[i] end
	if perf then fire(t, "create") end
	return t
end

local function destroy(t, run_event)
	if not t._alive then return end
	if run_event ~= false then fire(t, "destroy") end
	t._alive = false
	fire(t, "cleanup")
	by_id[t.id] = nil
end

-- iterate matching instances: target = class, instance, id number, all
local each
function each(target, f, include_inactive)
	if target == nil or target == noone then return end
	if type(target) == "number" then target = by_id[target] if not target then return end end
	if target == all then
		local snap = snapshot(instances)
		for _, t in ipairs(snap) do if t._alive and (t._active or include_inactive) then if f(t) == false then return end end end
		return
	end
	if type(target) == "table" and rawget(target, "__is_object") then
		local snap = {}
		for _, t in ipairs(instances) do
			if t._alive and (t._active or include_inactive) and is_child_of(t.object_index, target) then snap[#snap + 1] = t end
		end
		for _, t in ipairs(snap) do if t._alive then if f(t) == false then return end end end
		return
	end
	if type(target) == "table" and rawget(target, "_alive") ~= nil then
		if target._alive then f(target) end
		return
	end
	-- GML arrays of objects/instances: [objA, objB]
	if type(target) == "table" and target[0] ~= nil then
		local stop = false
		for i = 0, array_length(target) - 1 do
			each(target[i], function(t) if f(t) == false then stop = true return false end end, include_inactive)
			if stop then return end
		end
	end
end
gm.each = each

-- GML `with (target) { ... }`  ->  with_(target, function(self) ... end)
-- inside the function, `other` in GML is the instance that called with_ (capture it as a local).
function with_(target, f)
	local prev = gm.current
	each(target, function(t)
		gm.current = t
		local ok, err = xpcall(function() return f(t) end, traceback)
		gm.current = prev
		if not ok then report("with_", err) if gm.strict then error(err, 0) end end
		if t._break then t._break = nil return false end
	end)
	gm.current = prev
end
gm.with = with_

function instance_destroy(target, run_event)
	if target == nil then target = gm.current end
	if type(target) == "boolean" then run_event = target target = gm.current end
	each(target, function(t) destroy(t, run_event) end)
end

function instance_exists(target)
	if target == nil or target == noone then return false end
	if type(target) == "number" then local t = by_id[target] return t ~= nil and t._alive and t._active end
	if type(target) == "table" and rawget(target, "__is_object") then
		for _, t in ipairs(instances) do
			if t._alive and t._active and is_child_of(t.object_index, target) then return true end
		end
		return false
	end
	if type(target) == "table" then return target._alive == true and target._active ~= false end
	return false
end
function instance_number(cls)
	local n = 0
	each(cls, function() n = n + 1 end)
	return n
end
function instance_find(cls, n)
	local i, found = 0, noone
	each(cls, function(t) if i == n then found = t return false end i = i + 1 end)
	return found
end
-- GML `objX.var` (read) means "the first instance of objX": use first(objX).var
function first(cls)
	if type(cls) == "number" then return by_id[cls] end
	if type(cls) == "table" and not rawget(cls, "__is_object") then return cls end
	local f = instance_find(cls, 0)
	if f == noone then return nil end
	return f
end
function instance_nearest(x, y, cls)
	local best, bd = noone, math.huge
	each(cls, function(t)
		local d = (t.x - x) ^ 2 + (t.y - y) ^ 2
		if d < bd then bd, best = d, t end
	end)
	return best
end
function instance_furthest(x, y, cls)
	local best, bd = noone, -1
	each(cls, function(t)
		local d = (t.x - x) ^ 2 + (t.y - y) ^ 2
		if d > bd then bd, best = d, t end
	end)
	return best
end
function instance_id_get(id) return by_id[id] or noone end
gm.instances = function() return instances end

function instance_deactivate_object(target) each(target, function(t) t._active = false end) end
function instance_activate_object(target) each(target, function(t) t._active = true end, true) end
function instance_deactivate_all(notme)
	local me = gm.current
	for _, t in ipairs(instances) do if not (notme and t == me) then t._active = false end end
end
function instance_activate_all() for _, t in ipairs(instances) do t._active = true end end
function instance_deactivate_region(l, t_, w, h, inside, notme) end
function instance_activate_region(l, t_, w, h, inside) instance_activate_all() end
function instance_change(cls, perf)
	local s = gm.current
	if perf then fire(s, "destroy") end
	rawset(s, "object_index", cls)
	local om = META.objects[cls.__name] or {}
	s.sprite_index = om.sprite
	s.mask_index = om.mask
	if perf then fire(s, "create") end
end

-- ------------------------------------------------------------------ collisions (bounding boxes)
local function overlaps(a, ax, ay, b)
	local l1, t1, r1, b1 = rect_at(a, ax, ay)
	if not l1 then return false end
	local l2, t2, r2, b2 = rect_at(b, b.x, b.y)
	if not l2 then return false end
	return l1 < r2 and l2 < r1 and t1 < b2 and t2 < b1
end
gm.overlaps = overlaps

function instance_place(x, y, target, self)
	self = self or gm.current
	local hit = noone
	each(target, function(t)
		if t ~= self and overlaps(self, x, y, t) then hit = t return false end
	end)
	return hit
end
function place_meeting(x, y, target, self) return instance_place(x, y, target, self) ~= noone end
function instance_place_list(x, y, target, list, ordered, self)
	self = self or gm.current
	local n = 0
	each(target, function(t) if t ~= self and overlaps(self, x, y, t) then array_push(list, t) n = n + 1 end end)
	return n
end
function place_free(x, y, self)
	self = self or gm.current
	local free = true
	each(all, function(t) if t ~= self and t.solid and overlaps(self, x, y, t) then free = false return false end end)
	return free
end
function place_empty(x, y, target, self) return not place_meeting(x, y, target or all, self) end

local function point_in(t, px, py)
	local l, tp, r, b = rect_at(t, t.x, t.y)
	return l and px >= l and px < r and py >= tp and py < b
end
gm.point_in = point_in
function instance_position(x, y, target)
	local hit = noone
	each(target, function(t) if point_in(t, x, y) then hit = t return false end end)
	return hit
end
function position_meeting(x, y, target) return instance_position(x, y, target) ~= noone end
function instance_position_list(x, y, target, list)
	local n = 0
	each(target, function(t) if point_in(t, x, y) then array_push(list, t) n = n + 1 end end)
	return n
end
function position_empty(x, y) return not position_meeting(x, y, all) end
function collision_point(x, y, target, prec, notme)
	local me = gm.current
	local hit = noone
	each(target, function(t) if not (notme and t == me) and point_in(t, x, y) then hit = t return false end end)
	return hit
end
function collision_point_list(x, y, target, prec, notme, list)
	local me, n = gm.current, 0
	each(target, function(t) if not (notme and t == me) and point_in(t, x, y) then array_push(list, t) n = n + 1 end end)
	return n
end
function collision_rectangle(x1, y1, x2, y2, target, prec, notme)
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	local me, hit = gm.current, noone
	each(target, function(t)
		if not (notme and t == me) then
			local l, tp, r, b = rect_at(t, t.x, t.y)
			if l and x1 < r and l <= x2 and y1 < b and tp <= y2 then hit = t return false end
		end
	end)
	return hit
end
function collision_rectangle_list(x1, y1, x2, y2, target, prec, notme, list)
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	local me, n = gm.current, 0
	each(target, function(t)
		if not (notme and t == me) then
			local l, tp, r, b = rect_at(t, t.x, t.y)
			if l and x1 < r and l <= x2 and y1 < b and tp <= y2 then array_push(list, t) n = n + 1 end
		end
	end)
	return n
end
function collision_circle(cx, cy, rad, target, prec, notme)
	local me, hit = gm.current, noone
	each(target, function(t)
		if not (notme and t == me) then
			local l, tp, r, b = rect_at(t, t.x, t.y)
			if l then
				local nx, ny = clamp(cx, l, r), clamp(cy, tp, b)
				if (nx - cx) ^ 2 + (ny - cy) ^ 2 <= rad * rad then hit = t return false end
			end
		end
	end)
	return hit
end
local function seg_rect(x1, y1, x2, y2, l, tp, r, b)
	local t0, t1 = 0, 1
	local dx, dy = x2 - x1, y2 - y1
	local p = {-dx, dx, -dy, dy}
	local q = {x1 - l, r - x1, y1 - tp, b - y1}
	for i = 1, 4 do
		if p[i] == 0 then
			if q[i] < 0 then return false end
		else
			local u = q[i] / p[i]
			if p[i] < 0 then if u > t1 then return false elseif u > t0 then t0 = u end
			else if u < t0 then return false elseif u < t1 then t1 = u end end
		end
	end
	return true
end
function collision_line(x1, y1, x2, y2, target, prec, notme)
	local me, hit = gm.current, noone
	each(target, function(t)
		if not (notme and t == me) then
			local l, tp, r, b = rect_at(t, t.x, t.y)
			if l and seg_rect(x1, y1, x2, y2, l, tp, r, b) then hit = t return false end
		end
	end)
	return hit
end
function distance_to_point(px, py)
	local s = gm.current
	local l, tp, r, b = rect_at(s, s.x, s.y)
	if not l then return point_distance(s.x, s.y, px, py) end
	local dx = math.max(l - px, 0, px - (r - 1))
	local dy = math.max(tp - py, 0, py - (b - 1))
	return sqrt(dx * dx + dy * dy)
end
function distance_to_object(target)
	local s = gm.current
	local best = math.huge
	local l1, t1, r1, b1 = rect_at(s, s.x, s.y)
	each(target, function(t)
		if t ~= s then
			local l2, t2, r2, b2 = rect_at(t, t.x, t.y)
			local d
			if l1 and l2 then
				local dx = math.max(l2 - r1, 0, l1 - r2)
				local dy = math.max(t2 - b1, 0, t1 - b2)
				d = sqrt(dx * dx + dy * dy)
			else
				d = point_distance(s.x, s.y, t.x, t.y)
			end
			if d < best then best = d end
		end
	end)
	return best
end

-- ------------------------------------------------------------------ motion helpers (current instance)
function motion_set(dir, spd) local s = gm.current s.direction = dir s.speed = spd end
function motion_add(dir, spd)
	local s = gm.current
	local h, v = s.hspeed + lengthdir_x(spd, dir), s.vspeed + lengthdir_y(spd, dir)
	s.hspeed, s.vspeed = h, v
end
function move_towards_point(x, y, spd)
	local s = gm.current
	s.direction = point_direction(s.x, s.y, x, y)
	s.speed = spd
end
function move_snap(hs, vs) local s = gm.current s.x = round(s.x / hs) * hs s.y = round(s.y / vs) * vs end
function place_snapped(hs, vs) local s = gm.current return s.x % hs == 0 and s.y % vs == 0 end
function move_wrap(hor, vert, margin)
	local s = gm.current
	local rw, rh = room_width, room_height
	if hor then if s.x < -margin then s.x = s.x + rw + margin * 2 elseif s.x > rw + margin then s.x = s.x - rw - margin * 2 end end
	if vert then if s.y < -margin then s.y = s.y + rh + margin * 2 elseif s.y > rh + margin then s.y = s.y - rh - margin * 2 end end
end
function move_contact_solid(dir, maxd)
	local s = gm.current
	maxd = (maxd and maxd > 0) and maxd or 1000
	local dx, dy = lengthdir_x(1, dir), lengthdir_y(1, dir)
	for i = 1, maxd do
		if not place_free(s.x + dx, s.y + dy) then return end
		s.x, s.y = s.x + dx, s.y + dy
	end
end
function move_outside_solid(dir, maxd)
	local s = gm.current
	maxd = (maxd and maxd > 0) and maxd or 1000
	local dx, dy = lengthdir_x(1, dir), lengthdir_y(1, dir)
	for i = 1, maxd do
		if place_free(s.x, s.y) then return end
		s.x, s.y = s.x + dx, s.y + dy
	end
end
function move_bounce_solid(adv) local s = gm.current s.hspeed, s.vspeed = -s.hspeed, -s.vspeed end
move_bounce_all = move_bounce_solid

-- ------------------------------------------------------------------ drawing helpers that need self
function draw_self()
	local s = gm.current
	if s and s.sprite_index ~= nil and s.sprite_index ~= -1 then
		draw_sprite_ext(s.sprite_index, s.image_index, s.x, s.y, s.image_xscale, s.image_yscale, s.image_angle, s.image_blend, s.image_alpha)
	end
end

-- ------------------------------------------------------------------ input
local KEYS = {}        -- code -> held
local KEYS_P, KEYS_R = {}, {}   -- pressed / released this tick
local PEND_P, PEND_R = {}, {}
local MB, MB_P, MB_R, MPEND_P, MPEND_R = {}, {}, {}, {}, {}
local WHEEL_UP, WHEEL_DOWN, PWHEEL_UP, PWHEEL_DOWN = false, false, false, false
local mouse_dx, mouse_dy = 0, 0   -- display coordinates (y down)
keyboard_string = ""
keyboard_lastchar = ""
keyboard_lastkey = 0
keyboard_key = 0
local action_codes = {}

local ALIAS = {[16] = {160, 161}, [17] = {162, 163}, [18] = {164, 165}}

local function key_state(tbl, code)
	if code == 1 then return next(tbl) ~= nil end    -- vk_anykey
	if code == 0 then return next(tbl) == nil end    -- vk_nokey
	if type(code) == "string" then code = string.byte(code:upper()) end
	local al = ALIAS[code]
	if al then return tbl[al[1]] == true or tbl[al[2]] == true end
	return tbl[code] == true
end
function keyboard_check(code) return key_state(KEYS, code) end
function keyboard_check_pressed(code) return key_state(KEYS_P, code) end
function keyboard_check_released(code) return key_state(KEYS_R, code) end
function keyboard_check_direct(code) return key_state(KEYS, code) end
function keyboard_clear(code) KEYS[code] = nil KEYS_P[code] = nil end
function io_clear() for k in pairs(KEYS) do KEYS[k] = nil end for k in pairs(KEYS_P) do KEYS_P[k] = nil end for k in pairs(MB) do MB[k] = nil end for k in pairs(MB_P) do MB_P[k] = nil end end
local function mb_state(tbl, b)
	if b == -1 then return next(tbl) ~= nil end
	if b == 0 then return next(tbl) == nil end
	return tbl[b] == true
end
function mouse_check_button(b) return mb_state(MB, b) end
function mouse_check_button_pressed(b) return mb_state(MB_P, b) end
function mouse_check_button_released(b) return mb_state(MB_R, b) end
function mouse_wheel_up() return WHEEL_UP end
function mouse_wheel_down() return WHEEL_DOWN end
function mouse_clear(b) MB[b] = nil MB_P[b] = nil end
-- gamepads are not mapped
function gamepad_is_connected() return false end
function gamepad_button_check() return false end
function gamepad_button_check_pressed() return false end
function gamepad_axis_value() return 0 end
function gamepad_get_device_count() return 0 end

function gm.on_input(action_id, action)
	-- while an autotest script drives the game, ignore the real mouse/keyboard
	if gm.autotest_active then return end
	if action.x then
		local dw, dh = D.display_size()
		mouse_dx, mouse_dy = action.x, dh - action.y
	end
	if not action_id then return end
	local code = action_codes[action_id]
	if code then
		if action.pressed then KEYS[code] = true PEND_P[code] = true keyboard_lastkey = code keyboard_key = code
			if code == 8 then keyboard_string = keyboard_string:sub(1, -2) end
		elseif action.released then KEYS[code] = nil PEND_R[code] = true if keyboard_key == code then keyboard_key = 0 end end
		return
	end
	if action_id == hash("mb1") or action_id == hash("mb2") or action_id == hash("mb3") then
		local b = action_id == hash("mb1") and 1 or action_id == hash("mb2") and 2 or 3
		if action.pressed then MB[b] = true MPEND_P[b] = true
		elseif action.released then MB[b] = nil MPEND_R[b] = true end
	elseif action_id == hash("wheel_up") then
		if action.pressed or (action.value and action.value > 0) then PWHEEL_UP = true end
	elseif action_id == hash("wheel_down") then
		if action.pressed or (action.value and action.value > 0) then PWHEEL_DOWN = true end
	elseif action_id == hash("text") then
		keyboard_string = keyboard_string .. action.text
		keyboard_lastchar = action.text:sub(-1)
		if #keyboard_string > 1024 then keyboard_string = keyboard_string:sub(-1024) end
	end
end

local function latch_input()
	KEYS_P, PEND_P = PEND_P, {}
	KEYS_R, PEND_R = PEND_R, {}
	MB_P, MPEND_P = MPEND_P, {}
	MB_R, MPEND_R = MPEND_R, {}
	WHEEL_UP, PWHEEL_UP = PWHEEL_UP, false
	WHEEL_DOWN, PWHEEL_DOWN = PWHEEL_DOWN, false
end

-- ------------------------------------------------------------------ views / camera
local views = {}       -- views[0..7] = {visible, x, y, w, h, wport, hport, follow, hborder, vborder, hspeed, vspeed}
local views_enabled = false
view_camera = {}
view_visible = {}
view_wport, view_hport, view_xport, view_yport = {}, {}, {}, {}
view_enabled = false
for i = 0, 7 do view_camera[i] = i end

local function cam(c) return views[c or 0] or views[0] end
function camera_get_view_x(c) return cam(c).x end
function camera_get_view_y(c) return cam(c).y end
function camera_get_view_width(c) return cam(c).w end
function camera_get_view_height(c) return cam(c).h end
function camera_set_view_pos(c, x, y) local v = cam(c) v.x, v.y = x, y end
function camera_set_view_size(c, w, h) local v = cam(c) v.w, v.h = w, h end
function camera_set_view_target(c, inst) cam(c).follow_inst = inst end
function camera_get_view_target(c) return cam(c).follow_inst or noone end
function camera_set_view_border(c, h, v) local vv = cam(c) vv.hborder, vv.vborder = h, v end
function camera_set_view_speed(c, h, v) local vv = cam(c) vv.hspeed, vv.vspeed = h, v end
function camera_set_view_angle() end
function camera_get_view_angle() return 0 end
function camera_create() return 0 end
function camera_create_view(x, y, w, h) local v = cam(0) v.x, v.y, v.w, v.h = x, y, w, h return 0 end
function camera_destroy() end
function view_get_camera(i) return i end
function view_set_camera() end
function view_get_wport(i) return views[i or 0].wport end
function view_get_hport(i) return views[i or 0].hport end

local function update_view()
	local v = views[0]
	if not v then return end
	local tgt = v.follow_inst
	if (tgt == nil or not instance_exists(tgt)) and v.follow and G[v.follow] then
		local f = instance_find(G[v.follow], 0)
		if f ~= noone then tgt = f end
	end
	if tgt and tgt ~= noone and instance_exists(tgt) then
		local hb, vb = v.hborder or 0, v.vborder or 0
		if hb * 2 > v.w then hb = v.w / 2 end
		if vb * 2 > v.h then vb = v.h / 2 end
		local nx, ny = v.x, v.y
		if tgt.x - hb < nx then nx = tgt.x - hb end
		if tgt.x + hb > nx + v.w then nx = tgt.x + hb - v.w end
		if tgt.y - vb < ny then ny = tgt.y - vb end
		if tgt.y + vb > ny + v.h then ny = tgt.y + vb - v.h end
		if v.hspeed and v.hspeed >= 0 then nx = v.x + clamp(nx - v.x, -v.hspeed, v.hspeed) end
		if v.vspeed and v.vspeed >= 0 then ny = v.y + clamp(ny - v.y, -v.vspeed, v.vspeed) end
		nx = clamp(nx, 0, math.max(0, room_width - v.w))
		ny = clamp(ny, 0, math.max(0, room_height - v.h))
		v.x, v.y = nx, ny
	end
end

-- mouse_x / mouse_y in room coordinates are refreshed each tick
local function update_mouse()
	local v = views[0]
	if not v then local dw, dh = D.display_size() v = {x = 0, y = 0, w = dw, h = dh} end
	local dw, dh = D.display_size()
	mouse_x = v.x + mouse_dx * v.w / dw
	mouse_y = v.y + mouse_dy * v.h / dh
	local gw, gh = D.gui_size()
	gm.gui_mouse_x, gm.gui_mouse_y = mouse_dx * gw / dw, mouse_dy * gh / dh
end
function device_mouse_x_to_gui(dev) return gm.gui_mouse_x end
function device_mouse_y_to_gui(dev) return gm.gui_mouse_y end
function device_mouse_x(dev) return mouse_x end
function device_mouse_y(dev) return mouse_y end
function device_mouse_check_button(dev, b) return mouse_check_button(b) end
function device_mouse_check_button_pressed(dev, b) return mouse_check_button_pressed(b) end
function device_mouse_check_button_released(dev, b) return mouse_check_button_released(b) end
function window_mouse_get_x() return mouse_dx end
function window_mouse_get_y() return mouse_dy end
function window_mouse_set(x, y) end
function window_get_width() local w = D.display_size() return w end
function window_get_height() local _, h = D.display_size() return h end
function window_set_size(w, h) end
function window_center() end
function window_set_caption(s) end
function window_get_caption() return META.title end
function window_set_cursor(c) end
window_fullscreen = false
function window_get_fullscreen() return window_fullscreen end
function window_set_fullscreen(f)
	window_fullscreen = f
	if defos then defos.set_fullscreen(f) end
end
function display_get_width() local w = D.display_size() return w end
function display_get_height() local _, h = D.display_size() return h end
function display_get_gui_width() local w = D.gui_size() return w end
function display_get_gui_height() local _, h = D.gui_size() return h end
function display_set_gui_size(w, h) D.set_gui_size(w, h) end
function display_set_gui_maximise() D.set_gui_size(nil, nil) end
display_set_gui_maximize = display_set_gui_maximise
function application_get_position() local w, h = D.display_size() return arr(0, 0, w, h) end
function surface_get_width() local w = D.display_size() return w end
function surface_get_height() local _, h = D.display_size() return h end
application_surface = -1
cr_default, cr_none, cr_arrow, cr_handpoint = 0, -1, -2, -21

-- ------------------------------------------------------------------ rooms
room_width, room_height = 0, 0
room_speed = 60
room_persistent = false
room_first, room_last = nil, nil

local function room_index(name)
	for i, r in ipairs(META.room_order) do if r == name then return i end end
	return nil
end
function room_exists(name) return name ~= nil and META.rooms[name] ~= nil end
function room_get_name(name) return name end
function room_next(name) local i = room_index(name) return i and META.room_order[i + 1] or -1 end
function room_previous(name) local i = room_index(name) return i and META.room_order[i - 1] or -1 end
function room_goto(name)
	if not META.rooms[name] then print("room_goto: unknown room " .. tostring(name)) return end
	pending_room = name
end
function room_goto_next() local n = room_next(room) if n ~= -1 then room_goto(n) end end
function room_goto_previous() local n = room_previous(room) if n ~= -1 then room_goto(n) end end
function room_restart() pending_room = room end
function game_restart() pending_restart = true end
function game_end() pending_end = true end
function game_get_speed(kind) return room_speed end
function game_set_speed(v, kind) room_speed = v end
gamespeed_fps, gamespeed_microseconds = 0, 1

-- layers
function layer_get_id(name) local L = layer_by_name[name] return L and L.id or -1 end
function layer_exists(name) return layer_by_name[name] ~= nil end
function layer_get_depth(l) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) return L and L.depth or 0 end
function layer_set_visible(l, v) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) if L then L.visible = v end end
function layer_get_visible(l) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) return L and L.visible end
function layer_x(l, x) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) if L then L.x = x end end
function layer_y(l, y) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) if L then L.y = y end end
function layer_get_x(l) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) return L and L.x or 0 end
function layer_get_y(l) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) return L and L.y or 0 end
function layer_hspeed(l, v) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) if L then L.hspeed = v end end
function layer_vspeed(l, v) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) if L then L.vspeed = v end end
function layer_background_get_id(l) local L = type(l) == "string" and layer_by_name[l] or gm.layer_by_id(l) return L and L.id or -1 end
function layer_background_change(id, spr) local L = gm.layer_by_id(id) if L then L.sprite = spr end end
function layer_background_sprite(id, spr) layer_background_change(id, spr) end
function layer_background_blend(id, c) local L = gm.layer_by_id(id) if L then L.colour = c end end
function layer_background_alpha(id, a) local L = gm.layer_by_id(id) if L then L.alpha = a end end
function layer_background_visible(id, v) local L = gm.layer_by_id(id) if L then L.visible = v end end
function layer_background_index(id, i) local L = gm.layer_by_id(id) if L then L.frame = i end end
function gm.layer_by_id(id) for _, L in ipairs(room_layers) do if L.id == id then return L end end end
function gm.layer(name) return layer_by_name[name] end

local function build_layers(rd)
	room_layers = {}
	layer_by_name = {}
	for i, L in ipairs(rd.layers or {}) do
		local rl = {id = i, name = L.name, depth = L.depth, type = L.type, visible = L.visible ~= false,
			sprite = L.sprite, colour = L.colour or 16777215, alpha = L.alpha or 1, htiled = L.htiled, vtiled = L.vtiled,
			stretch = L.stretch, x = L.x or 0, y = L.y or 0, hspeed = L.hspeed or 0, vspeed = L.vspeed or 0,
			frame = 0, anim_fps = L.anim_fps or 0, anim_type = L.anim_type or 0, assets = L.assets}
		room_layers[#room_layers + 1] = rl
		layer_by_name[L.name] = rl
	end
end

local room_code
local function load_room(name)
	local rd = META.rooms[name]
	room = name
	room_name = name
	room_data = rd
	room_width, room_height = rd.width, rd.height
	room_persistent = rd.persistent
	build_layers(rd)
	-- views
	local dw, dh = D.display_size()
	views_enabled = rd.views_enabled
	view_enabled = views_enabled
	for i = 0, 7 do
		local v = rd.views and rd.views[i + 1]
		if views_enabled and v then
			views[i] = {visible = v.visible, x = v.x, y = v.y, w = v.w, h = v.h, wport = v.wport, hport = v.hport,
				follow = v.follow, hborder = v.hborder, vborder = v.vborder, hspeed = v.hspeed, vspeed = v.vspeed}
		else
			views[i] = {visible = i == 0, x = 0, y = 0, w = (i == 0 and not views_enabled) and rd.width or dw,
				h = (i == 0 and not views_enabled) and rd.height or dh, wport = dw, hport = dh}
		end
		view_visible[i] = views[i].visible
		view_wport[i], view_hport[i], view_xport[i], view_yport[i] = views[i].wport, views[i].hport, 0, 0
	end
	-- the display always shows view 0 scaled to the window
	-- instances
	local created = {}
	local saved = persistent_rooms[name]
	if saved then
		persistent_rooms[name] = nil
		for _, t in ipairs(saved) do instances[#instances + 1] = t by_id[t.id] = t end
	else
		for _, L in ipairs(rd.layers or {}) do
			for _, ri in ipairs(L.instances or {}) do
				local cls = OBJ[ri.obj]
				if cls then
					local t = new_instance(cls, ri.x, ri.y, L.depth, ri.props, L.name)
					t.image_xscale, t.image_yscale, t.image_angle = ri.sx or 1, ri.sy or 1, ri.rot or 0
					t.image_blend, t.image_alpha = ri.colour or 16777215, ri.alpha or 1
					t.image_index, t.image_speed = ri.frame or 0, ri.speed or 1
					t._room_inst = ri.name
					created[#created + 1] = {t, ri}
				end
			end
		end
		for _, c in ipairs(created) do
			fire(c[1], "create")
			local f = room_code and room_code[c[2].name]
			if f and c[1]._alive then call(c[1], f) end
		end
		local rc = room_code and room_code[name]
		if rc then
			local ok, err = xpcall(rc, traceback)
			if not ok then report("room creation code " .. name, err) end
		end
	end
	D.set_view(views[0].x, views[0].y, views[0].w, views[0].h)
end

local function change_room(name, first)
	-- room end
	if not first then
		for _, t in ipairs(snapshot(instances)) do if t._alive then fire(t, "room_end") end end
		-- remove non persistent instances (cleanup event, no destroy event)
		local keep, stash = {}, {}
		for _, t in ipairs(instances) do
			if t._alive then
				if t.persistent then keep[#keep + 1] = t
				elseif room_persistent then stash[#stash + 1] = t by_id[t.id] = nil
				else t._alive = false fire(t, "cleanup") by_id[t.id] = nil end
			end
		end
		if room_persistent then persistent_rooms[room] = stash end
		instances = keep
	end
	load_room(name)
	if first then
		for _, t in ipairs(snapshot(instances)) do if t._alive then fire(t, "game_start") end end
	end
	for _, t in ipairs(snapshot(instances)) do if t._alive then fire(t, "room_start") end end
end

-- ------------------------------------------------------------------ game loop
local function compact()
	local n = 0
	for i = 1, #instances do
		local t = instances[i]
		if t._alive then n = n + 1 instances[n] = t end
	end
	for i = #instances, n + 1, -1 do instances[i] = nil end
end

local function for_active(ev, f)
	local snap = snapshot(instances)
	for _, t in ipairs(snap) do
		if t._alive and t._active then
			if ev then
				local h = t.object_index[ev]
				if h then call(t, h) end
			else
				f(t)
			end
		end
	end
end

local MOUSE_EVS = {
	{"mouse_left_down", function() return MB[1] end}, {"mouse_right_down", function() return MB[2] end},
	{"mouse_middle_down", function() return MB[3] end}, {"mouse_no_button", function() return next(MB) == nil end},
	{"mouse_left_pressed", function() return MB_P[1] end}, {"mouse_right_pressed", function() return MB_P[2] end},
	{"mouse_middle_pressed", function() return MB_P[3] end},
	{"mouse_left_released", function() return MB_R[1] end}, {"mouse_right_released", function() return MB_R[2] end},
	{"mouse_middle_released", function() return MB_R[3] end},
}
local GLOBAL_MOUSE_EVS = {
	{"global_left_down", function() return MB[1] end}, {"global_right_down", function() return MB[2] end},
	{"global_middle_down", function() return MB[3] end},
	{"global_left_pressed", function() return MB_P[1] end}, {"global_right_pressed", function() return MB_P[2] end},
	{"global_middle_pressed", function() return MB_P[3] end},
	{"global_left_released", function() return MB_R[1] end}, {"global_right_released", function() return MB_R[2] end},
	{"global_middle_released", function() return MB_R[3] end},
	{"mouse_wheel_up", function() return WHEEL_UP end}, {"mouse_wheel_down", function() return WHEEL_DOWN end},
}

local function input_events()
	for_active(nil, function(t)
		local cls = t.object_index
		-- keyboard events
		if cls.__has_key_events then
			for code in pairs(KEYS) do local f = cls["key_down_" .. code] if f then call(t, f) end end
			for code in pairs(KEYS_P) do local f = cls["key_pressed_" .. code] if f then call(t, f) end end
			for code in pairs(KEYS_R) do local f = cls["key_released_" .. code] if f then call(t, f) end end
		end
		if cls.__has_mouse_events then
			local over = point_in(t, mouse_x, mouse_y)
			if over then
				for _, e in ipairs(MOUSE_EVS) do
					local f = cls[e[1]]
					if f and e[2]() and t._alive then call(t, f) end
				end
			end
			if cls.mouse_enter and over and not t._mouse_over and t._alive then call(t, cls.mouse_enter) end
			if cls.mouse_leave and not over and t._mouse_over and t._alive then call(t, cls.mouse_leave) end
			t._mouse_over = over
			for _, e in ipairs(GLOBAL_MOUSE_EVS) do
				local f = cls[e[1]]
				if f and e[2]() and t._alive then call(t, f) end
			end
		end
	end)
end

local function motion()
	for_active(nil, function(t)
		local fr = t.friction
		if fr ~= 0 then
			local s = t.speed
			if s > 0 then t.speed = math.max(0, s - fr) end
		end
		local g = t.gravity
		if g ~= 0 then
			local gd = t.gravity_direction
			rawset(t, "_hs", t.hspeed + lengthdir_x(g, gd))
			rawset(t, "_vs", t.vspeed + lengthdir_y(g, gd))
			local h, v = rawget(t, "_hs"), rawget(t, "_vs")
			if h ~= 0 or v ~= 0 then rawset(t, "_dir", point_direction(0, 0, h, v)) end
		end
		local h, v = rawget(t, "_hs"), rawget(t, "_vs")
		if h ~= 0 or v ~= 0 then t.x = t.x + h t.y = t.y + v end
	end)
end

local function collisions()
	for_active(nil, function(t)
		local col = t.object_index.collision
		if col then
			for oname, f in pairs(col) do
				local target = OBJ[oname]
				if target then
					each(target, function(o)
						if o ~= t and t._alive and o._alive and overlaps(t, t.x, t.y, o) then call(t, f, o) end
					end)
				end
			end
		end
	end)
end

local function animate()
	for_active(nil, function(t)
		local spr = rawget(t, "sprite_index")
		local s = spr and SPR[spr]
		if s and s.n > 0 then
			local sp = t.image_speed
			if sp ~= 0 then
				local inc = s.speed_type == 1 and s.speed * sp or s.speed / room_speed * sp
				local ii = t.image_index + inc
				if ii >= s.n then
					ii = ii - s.n * floor(ii / s.n)
					t.image_index = ii
					fire(t, "animation_end")
				elseif ii < 0 then
					ii = ii % s.n
					t.image_index = ii
					fire(t, "animation_end")
				else
					t.image_index = ii
				end
			end
		end
	end)
end

local function alarms()
	for_active(nil, function(t)
		local al = t.alarm
		for i = 0, 11 do
			local a = al[i]
			if a and a > 0 then
				a = a - 1
				if a <= 0 then
					al[i] = -1
					local f = t.object_index["alarm" .. i]
					if f then call(t, f) end
				else
					al[i] = a
				end
			end
		end
	end)
end

local function room_outside()
	for_active(nil, function(t)
		if t.object_index.outside_room then
			local l, tp, r, b = rect_at(t, t.x, t.y)
			if not l then l, tp, r, b = t.x, t.y, t.x, t.y end
			local out = r < 0 or l > room_width or b < 0 or tp > room_height
			if out and not t._outside then call(t, t.object_index.outside_room) end
			t._outside = out
		end
	end)
end

local function draw_background_layer(L)
	if not L.visible then return end
	if L.sprite then
		local m = SPR[L.sprite]
		if not m then return end
		if L.stretch then
			draw_sprite_stretched_ext(L.sprite, L.frame, 0, 0, room_width, room_height, L.colour, L.alpha)
		elseif L.htiled or L.vtiled then
			draw_sprite_tiled_ext(L.sprite, L.frame, L.x, L.y, 1, 1, L.colour, L.alpha)
		else
			draw_sprite_ext(L.sprite, L.frame, L.x + m.xo, L.y + m.yo, 1, 1, 0, L.colour, L.alpha)
		end
	else
		local v = views[0]
		D.fill(v.x, v.y, v.w, v.h, L.colour, L.alpha)
	end
end

local function draw_asset_layer(L)
	if not L.visible or not L.assets then return end
	for _, a in ipairs(L.assets) do
		draw_sprite_ext(a.sprite, a.frame or 0, a.x, a.y, a.sx, a.sy, a.rot, a.colour, a.alpha)
	end
end

local function draw_all()
	D.begin_frame()
	D.set_gui(false)
	local v = views[0]
	D.set_view(v.x, v.y, v.w, v.h)
	-- build depth-sorted draw list: layers (background/assets) and instances
	local list = {}
	for _, L in ipairs(room_layers) do
		if L.type == "background" or L.type == "assets" then list[#list + 1] = {d = L.depth, o = -1e9 + L.id, layer = L} end
	end
	for _, t in ipairs(instances) do
		if t._alive and t._active then list[#list + 1] = {d = t.depth, o = t._order, inst = t} end
	end
	table.sort(list, function(a, b) if a.d ~= b.d then return a.d > b.d end return a.o < b.o end)
	local function pass(ev, default_draw)
		for _, e in ipairs(list) do
			local t = e.inst
			if t then
				if t._alive and t.visible then
					local f = t.object_index[ev]
					if f then call(t, f)
					elseif default_draw then
						call(t, draw_self)
					end
				end
			elseif ev == "draw" then
				if e.layer.type == "background" then draw_background_layer(e.layer) else draw_asset_layer(e.layer) end
			end
		end
	end
	pass("draw_pre")
	pass("draw_begin")
	pass("draw", true)
	pass("draw_end")
	pass("draw_post")
	D.set_gui(true)
	pass("draw_gui_begin")
	pass("draw_gui")
	pass("draw_gui_end")
	D.set_gui(false)
	D.end_frame()
end

-- ------------------------------------------------------------------ autotest (scripted input for headless checks)
-- dmengine --config=gm.autotest="30:kd=68;60:ku=68;90:click=400,300;120:room=rmMain;150:print=player.x"
--   kd/ku/kp=CODE key down/up/press(1 tick)   mm=X,Y mouse move (display px, y down)
--   md/mu=B mouse button down/up              click=X,Y move + left click
--   room=NAME room_goto                       eval=LUA run a Lua chunk and print its result
--   quit                                      exit the engine
local autotest = {}
local function autotest_parse(s)
	for part in s:gmatch("[^;]+") do
		local t, a = part:match("^%s*(%d+)%s*:%s*(.-)%s*$")
		if t then
			t = tonumber(t)
			autotest[t] = autotest[t] or {}
			table.insert(autotest[t], a)
		end
	end
end
local function autotest_run(n)
	local list = autotest[n]
	if not list then return end
	for _, a in ipairs(list) do
		local k, v = a:match("^(%w+)=?(.*)$")
		if k == "kd" then local c = tonumber(v) KEYS[c] = true PEND_P[c] = true
		elseif k == "ku" then local c = tonumber(v) KEYS[c] = nil PEND_R[c] = true
		elseif k == "kp" then local c = tonumber(v) KEYS[c] = true PEND_P[c] = true
			autotest[n + 1] = autotest[n + 1] or {} table.insert(autotest[n + 1], "ku=" .. c)
		elseif k == "mm" then local x, y = v:match("([%-%d%.]+),([%-%d%.]+)") mouse_dx, mouse_dy = tonumber(x), tonumber(y)
		elseif k == "md" then local b = tonumber(v) or 1 MB[b] = true MPEND_P[b] = true
		elseif k == "mu" then local b = tonumber(v) or 1 MB[b] = nil MPEND_R[b] = true
		elseif k == "click" then
			local x, y = v:match("([%-%d%.]+),([%-%d%.]+)") mouse_dx, mouse_dy = tonumber(x), tonumber(y)
			MB[1] = true MPEND_P[1] = true
			autotest[n + 2] = autotest[n + 2] or {} table.insert(autotest[n + 2], "mu=1")
		elseif k == "room" then room_goto(v)
		elseif k == "eval" then
			local f, err = loadstring("return " .. v)
			if not f then f, err = loadstring(v) end
			if f then local ok, r = pcall(f) print("AUTOTEST eval [" .. v .. "] -> " .. tostring(ok and str(r) or r)) else print("AUTOTEST eval error " .. tostring(err)) end
		elseif k == "quit" then sys.exit(0)
		end
	end
end

local function tick()
	tick_no = tick_no + 1
	if next(autotest) then autotest_run(tick_no) end
	current_time = floor(tick_no * 1000 / room_speed)
	delta_time = floor(1000000 / room_speed)
	fps, fps_real = room_speed, room_speed
	latch_input()
	update_mouse()
	for _, t in ipairs(instances) do t.xprevious, t.yprevious = t.x, t.y end
	for_active("step_begin")
	alarms()
	input_events()
	for_active("step")
	motion()
	room_outside()
	collisions()
	for_active("step_end")
	animate()
	-- background layer scrolling / animation
	for _, L in ipairs(room_layers) do
		if L.hspeed ~= 0 then L.x = L.x + L.hspeed end
		if L.vspeed ~= 0 then L.y = L.y + L.vspeed end
		if L.sprite and SPR[L.sprite] and SPR[L.sprite].n > 1 and L.anim_fps > 0 then
			L.frame = L.frame + (L.anim_type == 1 and L.anim_fps or L.anim_fps / room_speed)
		end
	end
	update_view()
	compact()
	if pending_end then
		pending_end = false
		for _, t in ipairs(instances) do if t._alive then fire(t, "game_end") end end
		sys.exit(0)
	end
	if pending_restart then
		pending_restart = false
		pending_room = nil
		for _, t in ipairs(instances) do if t._alive then t._alive = false fire(t, "cleanup") end end
		instances, by_id, persistent_rooms = {}, {}, {}
		for k in pairs(global) do global[k] = nil end
		audio_stop_all()
		change_room(META.room_order[1], true)
		update_view()
	elseif pending_room then
		local r = pending_room
		pending_room = nil
		change_room(r, false)
		update_view()
		compact()
	end
	update_mouse()
end

-- ------------------------------------------------------------------ boot / update
local acc = 0
function gm.boot(meta, load_game)
	META = meta
	SPR = meta.sprites
	gm.meta = meta
	room_speed = meta.game_speed or 60
	D.init(meta)
	D.set_fonts(meta.fonts)
	A.init(meta)
	-- input action -> GM key code
	for c = 0, 255 do action_codes[hash("k" .. c)] = c end
	-- classes for every object, then parents
	for name in pairs(meta.objects) do make_class(name) end
	for name, m in pairs(meta.objects) do
		local c = OBJ[name]
		if m.parent and OBJ[m.parent] then
			c.__parent = OBJ[m.parent]
			setmetatable(c, {__index = OBJ[m.parent]})
		end
	end
	-- globals for asset names: rooms, sprites, sounds, fonts are referenced by their name string
	for name in pairs(meta.rooms) do if G[name] == nil then G[name] = name end end
	for name in pairs(meta.sprites) do if G[name] == nil then G[name] = name end end
	for name in pairs(meta.sounds or {}) do if G[name] == nil then G[name] = name end end
	for name in pairs(meta.fonts or {}) do if G[name] == nil then G[name] = name end end
	room_first = meta.room_order[1]
	room_last = meta.room_order[#meta.room_order]
	room_order = meta.room_order
	local at = sys.get_config_string("gm.autotest", "")
	if at ~= "" then autotest_parse(at) gm.autotest_active = true print("AUTOTEST enabled") end
	gm.tick_no = function() return tick_no end
	load_game()
	room_code = package.loaded["game.room_code"]
	if type(room_code) ~= "table" then room_code = {} end
	-- flag classes that use keyboard/mouse events (inherit through parents)
	for name, c in pairs(OBJ) do
		local k, m = false, false
		local cc = c
		while cc do
			for key in pairs(cc) do
				if type(key) == "string" then
					if key:find("^key_") then k = true end
					if key:find("^mouse_") or key:find("^global_") then m = true end
				end
			end
			cc = cc.__parent
		end
		rawset(c, "__has_key_events", k)
		rawset(c, "__has_mouse_events", m)
	end
	update_mouse()
	change_room(meta.room_order[1], true)
	update_view()
	draw_all()
end

function gm.update(dt)
	A.update(dt)
	acc = acc + dt
	local step = 1 / room_speed
	if acc > step * 5 then acc = step * 5 end
	local ran = false
	while acc >= step - 0.0005 do
		acc = acc - step
		tick()
		ran = true
	end
	if ran then draw_all() end
end

function gm.final() end

-- ------------------------------------------------------------------ persistence (ini files)
local ini_name, ini_data
local function ini_path(name) return sys.get_save_file(META.title:gsub("[^%w]", ""), (name or "save.ini"):gsub("[^%w%.]", "_")) end
function ini_open(name) ini_name = name ini_data = sys.load(ini_path(name)) or {} end
function ini_close() if ini_name then sys.save(ini_path(ini_name), ini_data) end ini_name = nil ini_data = nil return "" end
function ini_read_real(sec, key, def) local s = ini_data and ini_data[sec] local v = s and s[key] return type(v) == "number" and v or (tonumber(v) or def) end
function ini_read_string(sec, key, def) local s = ini_data and ini_data[sec] local v = s and s[key] return v ~= nil and tostring(v) or def end
function ini_write_real(sec, key, v) ini_data[sec] = ini_data[sec] or {} ini_data[sec][key] = v end
function ini_write_string(sec, key, v) ini_data[sec] = ini_data[sec] or {} ini_data[sec][key] = v end
function ini_key_exists(sec, key) return ini_data and ini_data[sec] and ini_data[sec][key] ~= nil end
function ini_section_exists(sec) return ini_data and ini_data[sec] ~= nil end
function ini_key_delete(sec, key) if ini_data and ini_data[sec] then ini_data[sec][key] = nil end end
function ini_section_delete(sec) if ini_data then ini_data[sec] = nil end end
function file_exists(name) return next(sys.load(ini_path(name))) ~= nil end
function file_delete(name) sys.save(ini_path(name), {}) end
-- simple whole-table save/load helpers
function gm.save_table(name, t) return sys.save(ini_path(name), t) end
function gm.load_table(name) return sys.load(ini_path(name)) end

os_type, os_windows, os_macosx, os_linux, os_browser = 0, 0, 1, 6, -1
os_browser = -1
debug_mode = false
function url_open(u) sys.open_url(u) end
function clipboard_set_text(s) end
function clipboard_get_text() return "" end

-- surfaces are not supported (Defold has no immediate render-to-texture from game code)
function surface_exists() return false end
function surface_create() return -1 end
function surface_free() end
function surface_set_target() return false end
function surface_reset_target() return false end
function surface_resize() end
function draw_surface() end
function draw_surface_ext() end

return gm
