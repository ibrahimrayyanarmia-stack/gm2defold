-- gm/lib.lua : GameMaker-style helper library (math, strings, arrays, ds_*, colours, constants).
-- Everything is exported as a Lua global with the GML name, so ported code reads like GML.
-- NOTE: GML arrays / ds_lists are 0-based. The array_* and ds_list_* helpers here operate on
-- 0-based Lua tables (t[0] .. t[n-1]). Use array_length(t) instead of #t for them.

local M = {}
local G = _G
local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs

local function export(name, v) M[name] = v; G[name] = v end

-- ------------------------------------------------------------------ constants
noone = -4
all = "__all__"
undefined = nil
pi = math.pi
infinity = math.huge
fa_left, fa_center, fa_right = 0, 1, 2
fa_top, fa_middle, fa_bottom = 0, 1, 2
mb_any, mb_none, mb_left, mb_right, mb_middle = -1, 0, 1, 2, 3
bm_normal, bm_add, bm_subtract, bm_max = 0, 1, 3, 2

vk_nokey, vk_anykey = 0, 1
vk_backspace, vk_tab, vk_enter, vk_return = 8, 9, 13, 13
vk_shift, vk_control, vk_alt = 16, 17, 18
vk_pause, vk_escape, vk_space = 19, 27, 32
vk_pageup, vk_pagedown, vk_end, vk_home = 33, 34, 35, 36
vk_left, vk_up, vk_right, vk_down = 37, 38, 39, 40
vk_insert, vk_delete = 45, 46
vk_lshift, vk_rshift, vk_lcontrol, vk_rcontrol, vk_lalt, vk_ralt = 160, 161, 162, 163, 164, 165
vk_multiply, vk_add, vk_subtract, vk_decimal, vk_divide = 106, 107, 109, 110, 111
for i = 0, 9 do G["vk_numpad" .. i] = 96 + i end
for i = 1, 12 do G["vk_f" .. i] = 111 + i end

-- colours are BGR integers like GameMaker: r + g*256 + b*65536
c_aqua, c_black, c_blue, c_dkgray, c_dkgrey = 16776960, 0, 16711680, 4210752, 4210752
c_fuchsia, c_gray, c_grey, c_green, c_lime = 16711935, 8421504, 8421504, 32768, 65280
c_ltgray, c_ltgrey, c_maroon, c_navy, c_olive = 12632256, 12632256, 128, 8388608, 32896
c_orange, c_purple, c_red, c_silver, c_teal = 4235519, 8388736, 255, 12632256, 8421376
c_white, c_yellow = 16777215, 65535

-- ------------------------------------------------------------------ math
export("round", function(x) return floor(x + 0.5) end)
export("floor", floor)
export("ceil", ceil)
export("abs", abs)
export("sqrt", sqrt)
export("sqr", function(x) return x * x end)
export("power", function(a, b) return a ^ b end)
export("exp", math.exp)
export("ln", math.log)
export("log2", function(x) return math.log(x) / math.log(2) end)
export("log10", function(x) return math.log(x) / math.log(10) end)
export("logn", function(n, x) return math.log(x) / math.log(n) end)
export("sin", math.sin)
export("cos", math.cos)
export("tan", math.tan)
export("arcsin", math.asin)
export("arccos", math.acos)
export("arctan", math.atan)
export("arctan2", function(y, x) return math.atan2(y, x) end)
export("dsin", function(d) return math.sin(math.rad(d)) end)
export("dcos", function(d) return math.cos(math.rad(d)) end)
export("dtan", function(d) return math.tan(math.rad(d)) end)
export("darcsin", function(x) return math.deg(math.asin(x)) end)
export("darccos", function(x) return math.deg(math.acos(x)) end)
export("darctan", function(x) return math.deg(math.atan(x)) end)
export("darctan2", function(y, x) return math.deg(math.atan2(y, x)) end)
export("degtorad", math.rad)
export("radtodeg", math.deg)
export("sign", function(x) if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end)
export("frac", function(x) return x - (x >= 0 and floor(x) or ceil(x)) end)
export("clamp", function(v, a, b) if v < a then return a elseif v > b then return b end return v end)
export("lerp", function(a, b, t) return a + (b - a) * t end)
export("max", math.max)
export("min", math.min)
export("mean", function(...) local s, n = 0, select("#", ...) for i = 1, n do s = s + select(i, ...) end return s / n end)
export("median", function(...) local t = {...} table.sort(t) return t[ceil(#t / 2)] end)
export("dot_product", function(x1, y1, x2, y2) return x1 * x2 + y1 * y2 end)
export("is_nan", function(x) return x ~= x end)
export("is_infinity", function(x) return x == math.huge or x == -math.huge end)

export("point_distance", function(x1, y1, x2, y2) local dx, dy = x2 - x1, y2 - y1 return sqrt(dx * dx + dy * dy) end)
export("point_direction", function(x1, y1, x2, y2)
	local d = math.deg(math.atan2(-(y2 - y1), x2 - x1))
	if d < 0 then d = d + 360 end
	return d
end)
export("lengthdir_x", function(len, dir) return len * math.cos(math.rad(dir)) end)
export("lengthdir_y", function(len, dir) return -len * math.sin(math.rad(dir)) end)
export("angle_difference", function(a, b) return ((a - b + 180) % 360) - 180 end)
export("point_in_rectangle", function(px, py, x1, y1, x2, y2) return px >= x1 and px <= x2 and py >= y1 and py <= y2 end)
export("point_in_circle", function(px, py, cx, cy, r) local dx, dy = px - cx, py - cy return dx * dx + dy * dy <= r * r end)
export("rectangle_in_rectangle", function(sx1, sy1, sx2, sy2, dx1, dy1, dx2, dy2)
	if sx2 < dx1 or sx1 > dx2 or sy2 < dy1 or sy1 > dy2 then return 0 end
	if sx1 >= dx1 and sx2 <= dx2 and sy1 >= dy1 and sy2 <= dy2 then return 1 end
	return 2
end)

-- ------------------------------------------------------------------ random
export("random", function(n) return math.random() * (n or 1) end)
export("random_range", function(a, b) return a + math.random() * (b - a) end)
export("irandom", function(n) n = floor(n) if n <= 0 then return 0 end return math.random(0, n) end)
export("irandom_range", function(a, b)
	a, b = floor(a), floor(b)
	if a > b then a, b = b, a end
	return math.random(a, b)
end)
export("choose", function(...) local n = select("#", ...) return (select(math.random(1, n), ...)) end)
local seed = os.time()
export("randomize", function() seed = os.time() + floor(os.clock() * 100000) math.randomseed(seed) return seed end)
export("randomise", G.randomize)
export("random_set_seed", function(s) seed = s math.randomseed(s) end)
export("random_get_seed", function() return seed end)
math.randomseed(seed)

-- ------------------------------------------------------------------ type checks
export("is_string", function(v) return type(v) == "string" end)
export("is_real", function(v) return type(v) == "number" end)
export("is_numeric", function(v) return type(v) == "number" end)
export("is_bool", function(v) return type(v) == "boolean" end)
export("is_array", function(v) return type(v) == "table" and getmetatable(v) == nil end)
export("is_struct", function(v) return type(v) == "table" end)
export("is_method", function(v) return type(v) == "function" end)
export("is_callable", function(v) return type(v) == "function" end)
export("is_undefined", function(v) return v == nil end)
export("bool", function(v) return v ~= nil and v ~= false and v ~= 0 and (type(v) ~= "number" or v > 0.5) end)
-- bool -> number (GML keyboard_check(...) - keyboard_check(...) etc.)
export("num", function(b) if b == true then return 1 elseif b == false or b == nil then return 0 end return b end)
-- GML truthiness (numbers > 0.5 are true). Use truthy(x) where GML relies on numeric booleans.
export("truthy", G.bool)

-- ------------------------------------------------------------------ strings (GML strings are 1-based)
local function gm_string(v)
	local t = type(v)
	if t == "number" then
		if v ~= v then return "NaN" end
		if v == floor(v) and abs(v) < 1e15 then return string.format("%d", v) end
		local s = string.format("%.2f", v)
		return s
	elseif t == "boolean" then
		return v and "1" or "0"
	elseif t == "nil" then
		return "undefined"
	elseif t == "table" then
		local parts = {}
		local n = G.array_length(v)
		if n > 0 then
			for i = 0, n - 1 do parts[#parts + 1] = gm_string(v[i]) end
			return "[ " .. table.concat(parts, ",") .. " ]"
		end
		for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. " : " .. gm_string(x) end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return tostring(v)
end
-- `string` is the Lua library, so GML string(x) is str(x)
export("str", function(...)
	local n = select("#", ...)
	if n <= 1 then return gm_string((...)) end
	-- string("{0} {1}", a, b) format form
	local fmt = (...)
	local args = {select(2, ...)}
	return (fmt:gsub("{(%d+)}", function(i) return gm_string(args[tonumber(i) + 1]) end))
end)
export("real", function(s) if type(s) == "number" then return s end return tonumber(s) or 0 end)
export("int64", function(s) return floor(G.real(s)) end)
export("string_length", function(s) return #gm_string(s) end)
export("string_char_at", function(s, i) s = gm_string(s) if i < 1 then i = 1 end return s:sub(i, i) end)
export("string_ord_at", function(s, i) return string.byte(gm_string(s), i) or 0 end)
export("string_byte_at", G.string_ord_at)
export("string_copy", function(s, i, n) s = gm_string(s) if i < 1 then i = 1 end return s:sub(i, i + n - 1) end)
export("string_delete", function(s, i, n) s = gm_string(s) return s:sub(1, i - 1) .. s:sub(i + n) end)
export("string_insert", function(sub, s, i) s = gm_string(s) return s:sub(1, i - 1) .. sub .. s:sub(i) end)
export("string_pos", function(sub, s) local i = string.find(gm_string(s), sub, 1, true) return i or 0 end)
export("string_last_pos", function(sub, s)
	s = gm_string(s) local last, i = 0, 0
	while true do i = string.find(s, sub, i + 1, true) if not i then return last end last = i end
end)
export("string_upper", function(s) return gm_string(s):upper() end)
export("string_lower", function(s) return gm_string(s):lower() end)
export("string_repeat", function(s, n) return string.rep(gm_string(s), n) end)
local function plain(p) return (p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
export("string_replace", function(s, a, b) return (gm_string(s):gsub(plain(a), (b:gsub("%%", "%%%%")), 1)) end)
export("string_replace_all", function(s, a, b) return (gm_string(s):gsub(plain(a), (b:gsub("%%", "%%%%")))) end)
export("string_count", function(sub, s) local _, n = gm_string(s):gsub(plain(sub), "") return n end)
export("string_digits", function(s) return (gm_string(s):gsub("%D", "")) end)
export("string_letters", function(s) return (gm_string(s):gsub("%A", "")) end)
export("string_lettersdigits", function(s) return (gm_string(s):gsub("%W", "")) end)
export("string_trim", function(s) return (gm_string(s):gsub("^%s+", ""):gsub("%s+$", "")) end)
export("string_starts_with", function(s, p) return gm_string(s):sub(1, #p) == p end)
export("string_ends_with", function(s, p) return p == "" or gm_string(s):sub(-#p) == p end)
export("string_format", function(v, tot, dec)
	local s = string.format("%." .. dec .. "f", v)
	if #s < tot then s = string.rep(" ", tot - #s) .. s end
	return s
end)
export("string_split", function(s, sep)
	local out, n, i = {}, 0, 1
	s = gm_string(s)
	while true do
		local j = string.find(s, sep, i, true)
		if not j then out[n] = s:sub(i) return out end
		out[n] = s:sub(i, j - 1) n = n + 1 i = j + #sep
	end
end)
export("ord", function(c) return string.byte(c, 1) or 0 end)
export("chr", function(n) return string.char(n) end)
export("ansi_char", G.chr)

-- ------------------------------------------------------------------ colours
export("make_colour_rgb", function(r, g, b) return floor(r) + floor(g) * 256 + floor(b) * 65536 end)
export("make_color_rgb", G.make_colour_rgb)
export("colour_get_red", function(c) return c % 256 end)
export("colour_get_green", function(c) return floor(c / 256) % 256 end)
export("colour_get_blue", function(c) return floor(c / 65536) % 256 end)
G.color_get_red, G.color_get_green, G.color_get_blue = G.colour_get_red, G.colour_get_green, G.colour_get_blue
export("make_colour_hsv", function(h, s, v) -- all 0..255 like GML
	h, s, v = (h % 256) / 255 * 360, s / 255, v / 255
	local c = v * s
	local x = c * (1 - abs((h / 60) % 2 - 1))
	local m = v - c
	local r, g, b
	if h < 60 then r, g, b = c, x, 0 elseif h < 120 then r, g, b = x, c, 0 elseif h < 180 then r, g, b = 0, c, x
	elseif h < 240 then r, g, b = 0, x, c elseif h < 300 then r, g, b = x, 0, c else r, g, b = c, 0, x end
	return G.make_colour_rgb((r + m) * 255 + 0.5, (g + m) * 255 + 0.5, (b + m) * 255 + 0.5)
end)
G.make_color_hsv = G.make_colour_hsv
export("merge_colour", function(c1, c2, t)
	local r = G.colour_get_red(c1) + (G.colour_get_red(c2) - G.colour_get_red(c1)) * t
	local g = G.colour_get_green(c1) + (G.colour_get_green(c2) - G.colour_get_green(c1)) * t
	local b = G.colour_get_blue(c1) + (G.colour_get_blue(c2) - G.colour_get_blue(c1)) * t
	return G.make_colour_rgb(r + 0.5, g + 0.5, b + 0.5)
end)
G.merge_color = G.merge_colour
export("colour_get_value", function(c) return math.max(G.colour_get_red(c), G.colour_get_green(c), G.colour_get_blue(c)) end)
G.color_get_value = G.colour_get_value

-- ------------------------------------------------------------------ 0-based arrays
local function alen(t)
	if t == nil then return 0 end
	local n = #t
	if t[0] ~= nil then return n + 1 end
	return 0 -- 0-based array with no element 0 is empty (tables built 1-based are NOT supported)
end
export("array_length", alen)
export("array_create", function(n, v)
	local t = {}
	for i = 0, (n or 0) - 1 do
		if type(v) == "function" then t[i] = v(i) else t[i] = v == nil and 0 or v end
	end
	return t
end)
-- array literal helper: arr(a, b, c) -> {[0]=a, [1]=b, [2]=c}
export("arr", function(...)
	local t, n = {}, select("#", ...)
	for i = 1, n do t[i - 1] = (select(i, ...)) end
	return t
end)
export("array_push", function(t, ...)
	local n = alen(t)
	for i = 1, select("#", ...) do t[n] = (select(i, ...)) n = n + 1 end
end)
export("array_pop", function(t)
	local n = alen(t)
	if n == 0 then return nil end
	local v = t[n - 1] t[n - 1] = nil return v
end)
export("array_shift", function(t)
	local n = alen(t)
	if n == 0 then return nil end
	local v = t[0]
	for i = 0, n - 2 do t[i] = t[i + 1] end
	t[n - 1] = nil
	return v
end)
export("array_insert", function(t, idx, ...)
	local n, k = alen(t), select("#", ...)
	for i = n - 1, idx, -1 do t[i + k] = t[i] end
	for i = 1, k do t[idx + i - 1] = (select(i, ...)) end
end)
export("array_delete", function(t, idx, cnt)
	cnt = cnt or 1
	local n = alen(t)
	if idx < 0 or idx >= n then return end
	if idx + cnt > n then cnt = n - idx end
	for i = idx, n - 1 - cnt do t[i] = t[i + cnt] end
	for i = n - cnt, n - 1 do t[i] = nil end
end)
export("array_resize", function(t, size)
	local n = alen(t)
	for i = n, size - 1 do t[i] = 0 end
	for i = size, n - 1 do t[i] = nil end
end)
export("array_get", function(t, i) return t[i] end)
export("array_set", function(t, i, v) t[i] = v end)
export("array_get_index", function(t, v)
	for i = 0, alen(t) - 1 do if t[i] == v then return i end end
	return -1
end)
export("array_contains", function(t, v) return G.array_get_index(t, v) >= 0 end)
export("array_copy", function(dst, di, src, si, len)
	local tmp = {}
	for i = 0, len - 1 do tmp[i] = src[si + i] end
	for i = 0, len - 1 do dst[di + i] = tmp[i] end
end)
export("array_clone", function(t) local c = {} for i = 0, alen(t) - 1 do c[i] = t[i] end return c end)
export("array_equals", function(a, b)
	local n = alen(a)
	if n ~= alen(b) then return false end
	for i = 0, n - 1 do if a[i] ~= b[i] then return false end end
	return true
end)
local function to1(t) local o = {} for i = 0, alen(t) - 1 do o[i + 1] = t[i] end return o end
local function back0(t, o) for i = 1, #o do t[i - 1] = o[i] end end
export("array_sort", function(t, asc)
	local o = to1(t)
	if type(asc) == "function" then
		table.sort(o, function(a, b) return asc(a, b) < 0 end)
	elseif asc == false then
		table.sort(o, function(a, b) return a > b end)
	else
		table.sort(o)
	end
	back0(t, o)
end)
export("array_shuffle", function(t)
	local c = G.array_clone(t)
	for i = alen(c) - 1, 1, -1 do local j = math.random(0, i) c[i], c[j] = c[j], c[i] end
	return c
end)
export("array_shuffle_ext", function(t)
	for i = alen(t) - 1, 1, -1 do local j = math.random(0, i) t[i], t[j] = t[j], t[i] end
end)
export("array_reverse", function(t) local c, n = {}, alen(t) for i = 0, n - 1 do c[i] = t[n - 1 - i] end return c end)
export("array_foreach", function(t, f) for i = 0, alen(t) - 1 do f(t[i], i) end end)
export("array_map", function(t, f) local c = {} for i = 0, alen(t) - 1 do c[i] = f(t[i], i) end return c end)
export("array_filter", function(t, f) local c, n = {}, 0 for i = 0, alen(t) - 1 do if f(t[i], i) then c[n] = t[i] n = n + 1 end end return c end)
export("array_any", function(t, f) for i = 0, alen(t) - 1 do if f(t[i], i) then return true end end return false end)
export("array_all", function(t, f) for i = 0, alen(t) - 1 do if not f(t[i], i) then return false end end return true end)
export("array_sum", function(t) local s = 0 for i = 0, alen(t) - 1 do s = s + t[i] end return s end)
-- iterate a 0-based array:  for i, v in ipairs0(t) do ... end
export("ipairs0", function(t)
	local i, n = -1, alen(t)
	return function() i = i + 1 if i < n then return i, t[i] end end
end)

-- ------------------------------------------------------------------ structs
export("variable_clone", function(v, depth)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = (type(x) == "table" and (depth == nil or depth > 0)) and G.variable_clone(x, depth and depth - 1) or x end
	return c
end)
export("struct_get_names", function(s) local o, n = {}, 0 for k in pairs(s) do o[n] = k n = n + 1 end return o end)
G.variable_struct_get_names = G.struct_get_names
export("struct_exists", function(s, k) return s[k] ~= nil end)
G.variable_struct_exists = G.struct_exists
export("struct_get", function(s, k) return s[k] end)
export("struct_set", function(s, k, v) s[k] = v end)
G.variable_struct_get, G.variable_struct_set = G.struct_get, G.struct_set
export("struct_remove", function(s, k) s[k] = nil end)
export("variable_instance_exists", function(i, k) return i ~= nil and i[k] ~= nil end)
export("variable_instance_get", function(i, k) return i[k] end)
export("variable_instance_set", function(i, k, v) i[k] = v end)
export("variable_global_exists", function(k) return G.global[k] ~= nil end)
export("variable_global_get", function(k) return G.global[k] end)
export("variable_global_set", function(k, v) G.global[k] = v end)

-- ------------------------------------------------------------------ ds_list (0-based) / ds_map / ds_grid / stack / queue
export("ds_list_create", function() return {} end)
export("ds_list_destroy", function(l) end)
export("ds_list_clear", function(l) for k in pairs(l) do l[k] = nil end end)
export("ds_list_size", alen)
export("ds_list_empty", function(l) return alen(l) == 0 end)
export("ds_list_add", G.array_push)
export("ds_list_find_value", function(l, i) return l[i] end)
export("ds_list_set", function(l, i, v) l[i] = v end)
export("ds_list_replace", function(l, i, v) l[i] = v end)
export("ds_list_delete", function(l, i) G.array_delete(l, i, 1) end)
export("ds_list_insert", function(l, i, v) G.array_insert(l, i, v) end)
export("ds_list_find_index", G.array_get_index)
export("ds_list_shuffle", G.array_shuffle_ext)
export("ds_list_sort", function(l, asc) G.array_sort(l, asc ~= false) end)
export("ds_exists", function(d) return d ~= nil end)
export("ds_map_create", function() return {} end)
export("ds_map_destroy", function(m) end)
export("ds_map_add", function(m, k, v) if m[k] == nil then m[k] = v end end)
export("ds_map_set", function(m, k, v) m[k] = v end)
export("ds_map_replace", function(m, k, v) m[k] = v end)
export("ds_map_find_value", function(m, k) return m[k] end)
export("ds_map_exists", function(m, k) return m[k] ~= nil end)
export("ds_map_delete", function(m, k) m[k] = nil end)
export("ds_map_clear", function(m) for k in pairs(m) do m[k] = nil end end)
export("ds_map_size", function(m) local n = 0 for _ in pairs(m) do n = n + 1 end return n end)
export("ds_map_keys_to_array", G.struct_get_names)
export("ds_grid_create", function(w, h)
	local g = {w = w, h = h}
	for x = 0, w - 1 do g[x] = {} for y = 0, h - 1 do g[x][y] = 0 end end
	return g
end)
export("ds_grid_destroy", function(g) end)
export("ds_grid_width", function(g) return g.w end)
export("ds_grid_height", function(g) return g.h end)
export("ds_grid_get", function(g, x, y) return g[x] and g[x][y] end)
export("ds_grid_set", function(g, x, y, v) g[x][y] = v end)
export("ds_grid_clear", function(g, v) for x = 0, g.w - 1 do for y = 0, g.h - 1 do g[x][y] = v end end end)
export("ds_stack_create", function() return {} end)
export("ds_stack_push", function(s, v) s[#s + 1] = v end)
export("ds_stack_pop", function(s) local v = s[#s] s[#s] = nil return v end)
export("ds_stack_top", function(s) return s[#s] end)
export("ds_stack_size", function(s) return #s end)
export("ds_stack_empty", function(s) return #s == 0 end)
export("ds_queue_create", function() return {} end)
export("ds_queue_enqueue", function(q, v) q[#q + 1] = v end)
export("ds_queue_dequeue", function(q) return table.remove(q, 1) end)
export("ds_queue_head", function(q) return q[1] end)
export("ds_queue_size", function(q) return #q end)
export("ds_queue_empty", function(q) return #q == 0 end)

-- ------------------------------------------------------------------ misc
export("show_debug_message", function(...) local t = {} for i = 1, select("#", ...) do t[i] = gm_string((select(i, ...))) end print(table.concat(t, " ")) end)
export("show_message", G.show_debug_message)
export("current_time_ms", function() return floor(socket and socket.gettime and socket.gettime() * 1000 or os.clock() * 1000) end)
export("get_timer", function() return floor((socket and socket.gettime and socket.gettime() or os.clock()) * 1000000) end)
export("date_current_datetime", function() return os.time() / 86400 + 25569 end)
export("method", function(ctx, f) return function(...) return f(ctx, ...) end end)

return M
