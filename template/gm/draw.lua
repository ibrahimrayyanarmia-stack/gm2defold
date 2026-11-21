-- gm/draw.lua : GameMaker immediate-mode drawing on top of pooled Defold sprites and labels.
-- Every frame the runtime calls D.begin_frame(), then draw_* calls claim pooled game objects
-- (sprites from factory #f_spr, labels from #f_lbl_<pivot>), then D.end_frame() hides the rest.
-- Coordinates are GameMaker room coordinates (y down). The active "view" (camera) maps room
-- coordinates to the display. Draw GUI events use GUI coordinates (display size by default).

local D = {}
local G = _G
local floor, abs = math.floor, math.abs

local meta_sprites
local DW, DH = 1280, 720
local view = {x = 0, y = 0, w = 1280, h = 720}
local gui = false
local gui_w, gui_h = nil, nil

local z_counter = 0
local Z0, ZSTEP = -0.99, 0.00001

local spr_pool, spr_used = {}, 0
local lbl_pools, lbl_used = {}, {}
local PIV = {"nw", "n", "ne", "w", "center", "e", "sw", "s", "se"}
local hash_cache = {}

-- draw state
local st = {colour = 16777215, alpha = 1, halign = 0, valign = 0, font = nil, fog = nil}
D.state = st

-- font metrics for /builtins/fonts/vera_mo_bd.ttf rendered at size 32 (gm.font)
local BASE = 32
local ADV = 0.6021 * BASE   -- monospace advance
local LINE = 1.164 * BASE   -- line height
local PT2PX = 1.333         -- GameMaker font "size" is in points

local function hcolor(c, a)
	c = c or 16777215
	return (c % 256) / 255, (floor(c / 256) % 256) / 255, (floor(c / 65536) % 256) / 255, a or 1
end
D.hcolor = hcolor

function D.init(meta)
	meta_sprites = meta.sprites
	DW, DH = meta.display_width, meta.display_height
	view.w, view.h = DW, DH
	for _, p in ipairs(PIV) do lbl_pools[p] = {} lbl_used[p] = 0 end
end

function D.display_size() return DW, DH end
function D.set_view(x, y, w, h) view.x, view.y, view.w, view.h = x, y, w or view.w, h or view.h end
function D.get_view() return view end
function D.set_gui(on) gui = on end
function D.set_gui_size(w, h) gui_w, gui_h = (w and w > 0) and w or nil, (h and h > 0) and h or nil end
function D.gui_size() return gui_w or DW, gui_h or DH end

-- room/gui coordinates -> display (defold world) coordinates, and the scale factors
local function tx(x, y)
	if gui then
		local gw, gh = gui_w or DW, gui_h or DH
		local kx, ky = DW / gw, DH / gh
		return x * kx, DH - y * ky, kx, ky
	end
	local kx, ky = DW / view.w, DH / view.h
	return (x - view.x) * kx, DH - (y - view.y) * ky, kx, ky
end
D.tx = tx

local function next_z()
	z_counter = z_counter + 1
	return Z0 + z_counter * ZSTEP
end

function D.begin_frame()
	z_counter = 0
	spr_used = 0
	for _, p in ipairs(PIV) do lbl_used[p] = 0 end
end

local function hide_rest(pool, used)
	for i = used + 1, #pool do
		local e = pool[i]
		if e.on then e.on = false msg.post(e.id, "disable") end
	end
end

function D.end_frame()
	hide_rest(spr_pool, spr_used)
	for _, p in ipairs(PIV) do hide_rest(lbl_pools[p], lbl_used[p]) end
end

local function claim_sprite()
	spr_used = spr_used + 1
	local e = spr_pool[spr_used]
	if not e then
		local id = factory.create("main:/main#f_spr", vmath.vector3(-10000, -10000, 0))
		e = {id = id, url = msg.url(nil, id, "sprite"), on = true}
		spr_pool[spr_used] = e
	elseif not e.on then
		e.on = true
		msg.post(e.id, "enable")
	end
	return e
end

local function anim_hash(name, f)
	local hs = hash_cache[name]
	if not hs then hs = {} hash_cache[name] = hs end
	local h = hs[f]
	if not h then h = hash(name .. "_" .. f) hs[f] = h end
	return h
end

local V3 = vmath.vector3
local V4 = vmath.vector4

-- low level: draw atlas image `anim` (hash) of size w,h with origin xo,yo
local function put(e, anim, w, h, xo, yo, x, y, xs, ys, rot, col, alpha)
	if xs == 0 or ys == 0 or xs ~= xs or ys ~= ys then
		go.set_position(V3(-100000, -100000, 0), e.id)
		return
	end
	if e.anim ~= anim then sprite.play_flipbook(e.url, anim) e.anim = anim end
	local px, py, kx, ky = tx(x, y)
	local ox, oy = (w * 0.5 - xo) * xs, -(h * 0.5 - yo) * ys   -- y up
	local zr = 0
	if rot ~= 0 then
		zr = math.rad(rot)
		local c, s = math.cos(zr), math.sin(zr)
		ox, oy = ox * c - oy * s, ox * s + oy * c
	end
	go.set_position(V3(px + ox * kx, py + oy * ky, next_z()), e.id)
	local sx, sy = abs(xs) * kx, abs(ys) * ky
	if e.sx ~= sx or e.sy ~= sy then go.set_scale(V3(sx, sy, 1), e.id) e.sx, e.sy = sx, sy end
	if e.rot ~= zr then go.set_rotation(vmath.quat_rotation_z(zr), e.id) e.rot = zr end
	local fx, fy = xs < 0, ys < 0
	if e.fx ~= fx then sprite.set_hflip(e.url, fx) e.fx = fx end
	if e.fy ~= fy then sprite.set_vflip(e.url, fy) e.fy = fy end
	local a = alpha * st.alpha_mult
	if e.col ~= col or e.alpha ~= a then
		local r, g, b = hcolor(col)
		go.set(e.url, "tint", V4(r, g, b, a))
		e.col, e.alpha = col, a
	end
	local fog = st.fog
	if e.fog ~= fog then
		if fog then
			local r, g, b = hcolor(fog)
			go.set(e.url, "fog", V4(r, g, b, 1))
		else
			go.set(e.url, "fog", V4(0, 0, 0, 0))
		end
		e.fog = fog
	end
end
st.alpha_mult = 1

function D.sprite_meta(spr)
	local m = meta_sprites[spr]
	if not m then error("unknown sprite " .. tostring(spr), 3) end
	return m
end

local function frame_of(m, sub)
	local n = m.n
	if n <= 1 then return 0 end
	local f = floor(sub or 0) % n
	return f
end

-- ------------------------------------------------------------------ sprites
function draw_sprite_ext(spr, sub, x, y, xs, ys, rot, col, alpha)
	if spr == nil or spr == -1 or spr == noone then return end
	local m = D.sprite_meta(spr)
	if m.n == 0 then return end
	put(claim_sprite(), anim_hash(spr, frame_of(m, sub)), m.w, m.h, m.xo, m.yo, x, y, xs or 1, ys or 1, rot or 0, col or 16777215, alpha or 1)
end
function draw_sprite(spr, sub, x, y)
	draw_sprite_ext(spr, sub, x, y, 1, 1, 0, 16777215, st.alpha)
end
function draw_sprite_stretched_ext(spr, sub, x, y, w, h, col, alpha)
	if spr == nil then return end
	local m = D.sprite_meta(spr)
	if m.n == 0 then return end
	put(claim_sprite(), anim_hash(spr, frame_of(m, sub)), m.w, m.h, 0, 0, x, y, w / m.w, h / m.h, 0, col or 16777215, alpha or 1)
end
function draw_sprite_stretched(spr, sub, x, y, w, h)
	draw_sprite_stretched_ext(spr, sub, x, y, w, h, 16777215, st.alpha)
end
function draw_sprite_tiled_ext(spr, sub, x, y, xs, ys, col, alpha)
	local m = D.sprite_meta(spr)
	local w, h = m.w * (xs or 1), m.h * (ys or 1)
	local vx, vy, vw, vh = view.x, view.y, view.w, view.h
	if gui then vx, vy, vw, vh = 0, 0, D.gui_size() end
	local sx = x - math.ceil((x - vx) / w) * w
	local sy = y - math.ceil((y - vy) / h) * h
	local yy = sy
	while yy < vy + vh do
		local xx = sx
		while xx < vx + vw do
			draw_sprite_ext(spr, sub, xx + m.xo * (xs or 1), yy + m.yo * (ys or 1), xs or 1, ys or 1, 0, col, alpha)
			xx = xx + w
		end
		yy = yy + h
	end
end
function draw_sprite_tiled(spr, sub, x, y) draw_sprite_tiled_ext(spr, sub, x, y, 1, 1, 16777215, st.alpha) end
-- NOTE: Defold sprites cannot crop UVs at runtime; draw_sprite_part* draws the part by scaling
-- only when the part is the whole sprite, otherwise it draws the full frame clipped to nothing.
-- Port code that relies on partial sprites (e.g. health bars) to rectangles instead.
function draw_sprite_part_ext(spr, sub, left, top, w, h, x, y, xs, ys, col, alpha)
	local m = D.sprite_meta(spr)
	if left == 0 and top == 0 then
		local sx, sy = (xs or 1), (ys or 1)
		if w >= m.w and h >= m.h then
			put(claim_sprite(), anim_hash(spr, frame_of(m, sub)), m.w, m.h, 0, 0, x, y, sx, sy, 0, col or 16777215, alpha or 1)
		end
	end
end
function draw_sprite_part(spr, sub, left, top, w, h, x, y) draw_sprite_part_ext(spr, sub, left, top, w, h, x, y, 1, 1, 16777215, st.alpha) end
function draw_sprite_general(spr, sub, left, top, w, h, x, y, xs, ys, rot, c1, c2, c3, c4, alpha)
	draw_sprite_ext(spr, sub, x, y, xs, ys, rot, c1, alpha)
end

-- ------------------------------------------------------------------ primitives
local PX = hash("__px")
local DISC = hash("__disc")

-- filled axis-aligned rectangle [x, x+w) x [y, y+h) in room units
local function fill(x, y, w, h, col, alpha, rot, ox, oy)
	if w == 0 or h == 0 then return end
	if w < 0 then x = x + w w = -w end
	if h < 0 then y = y + h h = -h end
	put(claim_sprite(), PX, 4, 4, ox or 0, oy or 0, x, y, w / 4, h / 4, rot or 0, col, alpha)
end
D.fill = fill

function draw_rectangle(x1, y1, x2, y2, outline)
	draw_rectangle_colour(x1, y1, x2, y2, st.colour, st.colour, st.colour, st.colour, outline)
end
function draw_rectangle_colour(x1, y1, x2, y2, c1, c2, c3, c4, outline)
	-- filled: GameMaker spans x1..x2+1 without sorting, so x2 == x1 - 1 draws nothing
	-- (e.g. an empty progress bar `draw_rectangle(bx, by, bx + w * 0 - 1, ...)`)
	local fw, fh = x2 - x1 + 1, y2 - y1 + 1
	local fx, fy = x1, y1
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	local col = c1
	if c1 ~= c2 or c1 ~= c3 or c1 ~= c4 then
		col = merge_colour(merge_colour(c1, c2, 0.5), merge_colour(c3, c4, 0.5), 0.5)
	end
	if outline then
		fill(x1, y1, x2 - x1 + 1, 1, col, st.alpha)
		fill(x1, y2, x2 - x1 + 1, 1, col, st.alpha)
		fill(x1, y1 + 1, 1, y2 - y1 - 1, col, st.alpha)
		fill(x2, y1 + 1, 1, y2 - y1 - 1, col, st.alpha)
	else
		fill(fx, fy, fw, fh, col, st.alpha)
	end
end
draw_rectangle_color = draw_rectangle_colour
function draw_roundrect(x1, y1, x2, y2, outline) draw_rectangle(x1, y1, x2, y2, outline) end
function draw_roundrect_ext(x1, y1, x2, y2, rx, ry, outline) draw_rectangle(x1, y1, x2, y2, outline) end
function draw_roundrect_colour(x1, y1, x2, y2, c1, c2, outline) draw_rectangle_colour(x1, y1, x2, y2, c1, c1, c2, c2, outline) end
draw_roundrect_color = draw_roundrect_colour
function draw_roundrect_colour_ext(x1, y1, x2, y2, rx, ry, c1, c2, outline) draw_rectangle_colour(x1, y1, x2, y2, c1, c1, c2, c2, outline) end
draw_roundrect_color_ext = draw_roundrect_colour_ext
function draw_point(x, y) fill(x, y, 1, 1, st.colour, st.alpha) end
function draw_point_colour(x, y, c) fill(x, y, 1, 1, c, st.alpha) end
draw_point_color = draw_point_colour

function draw_line_width_colour(x1, y1, x2, y2, w, c1, c2)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then return end
	local ang = point_direction(x1, y1, x2, y2)
	-- rectangle of length len, thickness w, origin at its left-middle, rotated
	put(claim_sprite(), PX, 4, 4, 0, 2, x1, y1, len / 4, w / 4, ang, c1 == c2 and c1 or merge_colour(c1, c2, 0.5), st.alpha)
end
draw_line_width_color = draw_line_width_colour
function draw_line_width(x1, y1, x2, y2, w) draw_line_width_colour(x1, y1, x2, y2, w, st.colour, st.colour) end
function draw_line(x1, y1, x2, y2) draw_line_width_colour(x1, y1, x2, y2, 1, st.colour, st.colour) end
function draw_line_colour(x1, y1, x2, y2, c1, c2) draw_line_width_colour(x1, y1, x2, y2, 1, c1, c2) end
draw_line_color = draw_line_colour
function draw_arrow(x1, y1, x2, y2, size)
	draw_line(x1, y1, x2, y2)
	local d = point_direction(x1, y1, x2, y2)
	draw_line(x2, y2, x2 + lengthdir_x(size, d + 150), y2 + lengthdir_y(size, d + 150))
	draw_line(x2, y2, x2 + lengthdir_x(size, d - 150), y2 + lengthdir_y(size, d - 150))
end

local circle_precision = 24
function draw_set_circle_precision(n) circle_precision = math.max(4, n) end

function draw_ellipse_colour(x1, y1, x2, y2, c1, c2, outline)
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	local cx, cy, rx, ry = (x1 + x2) / 2, (y1 + y2) / 2, (x2 - x1) / 2, (y2 - y1) / 2
	if outline then
		local px, py = cx + rx, cy
		for i = 1, circle_precision do
			local a = i / circle_precision * math.pi * 2
			local nx, ny = cx + math.cos(a) * rx, cy + math.sin(a) * ry
			draw_line_width_colour(px, py, nx, ny, 1, c2, c2)
			px, py = nx, ny
		end
	else
		put(claim_sprite(), DISC, 64, 64, 32, 32, cx, cy, rx * 2 / 64, ry * 2 / 64, 0, c1 == c2 and c1 or merge_colour(c1, c2, 0.5), st.alpha)
	end
end
draw_ellipse_color = draw_ellipse_colour
function draw_ellipse(x1, y1, x2, y2, outline) draw_ellipse_colour(x1, y1, x2, y2, st.colour, st.colour, outline) end
function draw_circle_colour(x, y, r, c1, c2, outline) draw_ellipse_colour(x - r, y - r, x + r, y + r, c1, c2, outline) end
draw_circle_color = draw_circle_colour
function draw_circle(x, y, r, outline) draw_circle_colour(x, y, r, st.colour, st.colour, outline) end

-- filled triangle approximated by horizontal spans (good enough for small UI triangles)
function draw_triangle_colour(x1, y1, x2, y2, x3, y3, c1, c2, c3, outline)
	local col = c1
	if outline then
		draw_line_colour(x1, y1, x2, y2, col, col)
		draw_line_colour(x2, y2, x3, y3, col, col)
		draw_line_colour(x3, y3, x1, y1, col, col)
		return
	end
	local pts = {{x1, y1}, {x2, y2}, {x3, y3}}
	table.sort(pts, function(a, b) return a[2] < b[2] end)
	local ya, yb = math.floor(pts[1][2]), math.ceil(pts[3][2])
	local function xat(p, q, y)
		if q[2] == p[2] then return nil end
		local t = (y - p[2]) / (q[2] - p[2])
		if t < 0 or t > 1 then return nil end
		return p[1] + (q[1] - p[1]) * t
	end
	for y = ya, yb - 1 do
		local yc = y + 0.5
		local xs = {}
		for _, e in ipairs({{1, 2}, {2, 3}, {1, 3}}) do
			local v = xat(pts[e[1]], pts[e[2]], yc)
			if v then xs[#xs + 1] = v end
		end
		if #xs >= 2 then
			local a, b = math.min(xs[1], xs[2], xs[3] or xs[1]), math.max(xs[1], xs[2], xs[3] or xs[1])
			fill(a, y, b - a, 1, col, st.alpha)
		end
	end
end
draw_triangle_color = draw_triangle_colour
function draw_triangle(x1, y1, x2, y2, x3, y3, outline) draw_triangle_colour(x1, y1, x2, y2, x3, y3, st.colour, st.colour, st.colour, outline) end

function draw_healthbar(x1, y1, x2, y2, amount, backcol, mincol, maxcol, direction, showback, showborder)
	amount = clamp(amount, 0, 100) / 100
	if showback then fill(x1, y1, x2 - x1 + 1, y2 - y1 + 1, backcol, st.alpha) end
	local col = merge_colour(mincol, maxcol, amount)
	local w, h = (x2 - x1 + 1), (y2 - y1 + 1)
	if direction == 0 then fill(x1, y1, w * amount, h, col, st.alpha)
	elseif direction == 1 then fill(x2 + 1 - w * amount, y1, w * amount, h, col, st.alpha)
	elseif direction == 2 then fill(x1, y1, w, h * amount, col, st.alpha)
	else fill(x1, y2 + 1 - h * amount, w, h * amount, col, st.alpha) end
	if showborder then
		local c = st.colour
		st.colour = c_black
		draw_rectangle(x1, y1, x2, y2, true)
		st.colour = c
	end
end

-- clear the whole view/gui with a colour (call from a draw event)
function draw_clear_alpha(col, alpha)
	local was = st.alpha_mult
	if gui then
		local gw, gh = D.gui_size()
		fill(0, 0, gw, gh, col, alpha)
	else
		fill(view.x, view.y, view.w, view.h, col, alpha)
	end
end
function draw_clear(col) draw_clear_alpha(col, 1) end

-- ------------------------------------------------------------------ draw state
function draw_set_colour(c) st.colour = c end
draw_set_color = draw_set_colour
function draw_get_colour() return st.colour end
draw_get_color = draw_get_colour
function draw_set_alpha(a) st.alpha = a end
function draw_get_alpha() return st.alpha end
function draw_set_halign(h) st.halign = h end
function draw_set_valign(v) st.valign = v end
function draw_get_halign() return st.halign end
function draw_get_valign() return st.valign end
function draw_set_font(f) st.font = f end
function draw_get_font() return st.font end
-- gpu_set_fog(enable, colour, start, end): draws sprites as a solid colour (used for hit flashes)
function gpu_set_fog(enable, col) if enable == true or (type(enable) == "table") then st.fog = type(enable) == "table" and enable[1] or col else st.fog = nil end end
function gpu_set_blendmode() end
function gpu_set_texfilter() end
function gpu_set_alphatestenable() end
function shader_set() end
function shader_reset() end

-- ------------------------------------------------------------------ text
local fonts_meta = {}
function D.set_fonts(f) fonts_meta = f or {} end

-- scale factor from our 32px font to the current GameMaker font
local function font_scale(f)
	f = f or st.font
	local size = 12
	if type(f) == "string" and fonts_meta[f] then size = fonts_meta[f].size
	elseif type(f) == "number" and f > 0 then size = f
	elseif type(f) == "table" and f.size then size = f.size end
	return size * PT2PX / LINE
end
D.font_scale = font_scale

local function split_lines(s)
	local lines = {}
	s = s:gsub("\r", "")
	for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
	return lines
end

local function wrap(s, w, sc)
	if not w or w <= 0 then return s end
	local maxc = math.max(1, math.floor(w / (ADV * sc)))
	local out = {}
	for _, line in ipairs(split_lines(s)) do
		local cur = ""
		for word in line:gmatch("%S+") do
			if cur == "" then cur = word
			elseif #cur + 1 + #word <= maxc then cur = cur .. " " .. word
			else out[#out + 1] = cur cur = word end
			while #cur > maxc do out[#out + 1] = cur:sub(1, maxc) cur = cur:sub(maxc + 1) end
		end
		out[#out + 1] = cur
	end
	return table.concat(out, "\n")
end

function string_width(s)
	s = str(s)
	local m = 0
	for _, l in ipairs(split_lines(s)) do if #l > m then m = #l end end
	return m * ADV * font_scale()
end
function string_height(s)
	return #split_lines(str(s)) * LINE * font_scale()
end
function string_width_ext(s, sep, w) return math.min(string_width(wrap(str(s), w, font_scale())), w > 0 and w or math.huge) end
function string_height_ext(s, sep, w) return string_height(wrap(str(s), w, font_scale())) end

local function draw_label(x, y, s, xs, ys, rot, col, alpha)
	s = str(s)
	if s == "" or xs == 0 or ys == 0 then return end
	local h, v = st.halign or 0, st.valign or 0
	local piv = PIV[v * 3 + h + 1]
	local pool = lbl_pools[piv]
	local n = lbl_used[piv] + 1
	lbl_used[piv] = n
	local e = pool[n]
	if not e then
		local id = factory.create("main:/main#f_lbl_" .. piv, vmath.vector3(-10000, -10000, 0))
		e = {id = id, url = msg.url(nil, id, "label"), on = true}
		pool[n] = e
	elseif not e.on then
		e.on = true
		msg.post(e.id, "enable")
	end
	if e.text ~= s then label.set_text(e.url, s) e.text = s end
	local px, py, kx, ky = tx(x, y)
	go.set_position(V3(px, py, next_z()), e.id)
	local sc = font_scale()
	local sx, sy = sc * (xs or 1) * kx, sc * (ys or 1) * ky
	if e.sx ~= sx or e.sy ~= sy then go.set_scale(V3(abs(sx), abs(sy), 1), e.id) e.sx, e.sy = sx, sy end
	local zr = math.rad(rot or 0)
	if e.rot ~= zr then go.set_rotation(vmath.quat_rotation_z(zr), e.id) e.rot = zr end
	local a = (alpha or st.alpha) * st.alpha_mult
	if e.col ~= col or e.alpha ~= a then
		local r, g, b = hcolor(col)
		go.set(e.url, "color", V4(r, g, b, a))
		e.col, e.alpha = col, a
	end
end
D.draw_label = draw_label

function draw_text(x, y, s) draw_label(x, y, s, 1, 1, 0, st.colour, st.alpha) end
function draw_text_colour(x, y, s, c1, c2, c3, c4, alpha) draw_label(x, y, s, 1, 1, 0, c1, alpha) end
draw_text_color = draw_text_colour
function draw_text_transformed(x, y, s, xs, ys, rot) draw_label(x, y, s, xs, ys, rot, st.colour, st.alpha) end
function draw_text_transformed_colour(x, y, s, xs, ys, rot, c1, c2, c3, c4, alpha) draw_label(x, y, s, xs, ys, rot, c1, alpha) end
draw_text_transformed_color = draw_text_transformed_colour
function draw_text_ext(x, y, s, sep, w) draw_label(x, y, wrap(str(s), w, font_scale()), 1, 1, 0, st.colour, st.alpha) end
function draw_text_ext_colour(x, y, s, sep, w, c1, c2, c3, c4, alpha) draw_label(x, y, wrap(str(s), w, font_scale()), 1, 1, 0, c1, alpha) end
draw_text_ext_color = draw_text_ext_colour
function draw_text_ext_transformed(x, y, s, sep, w, xs, ys, rot) draw_label(x, y, wrap(str(s), w, font_scale() * (xs or 1)), xs, ys, rot, st.colour, st.alpha) end
function draw_text_ext_transformed_colour(x, y, s, sep, w, xs, ys, rot, c1, c2, c3, c4, alpha) draw_label(x, y, wrap(str(s), w, font_scale() * (xs or 1)), xs, ys, rot, c1, alpha) end
draw_text_ext_transformed_color = draw_text_ext_transformed_colour

-- ------------------------------------------------------------------ sprite info
function sprite_get_width(spr) return D.sprite_meta(spr).w end
function sprite_get_height(spr) return D.sprite_meta(spr).h end
function sprite_get_xoffset(spr) return D.sprite_meta(spr).xo end
function sprite_get_yoffset(spr) return D.sprite_meta(spr).yo end
function sprite_get_number(spr) return D.sprite_meta(spr).n end
function sprite_get_speed(spr) return D.sprite_meta(spr).speed end
function sprite_get_name(spr) return spr end
function sprite_exists(spr) return spr ~= nil and meta_sprites[spr] ~= nil end
function sprite_get_bbox_left(spr) return D.sprite_meta(spr).bbox[1] end
function sprite_get_bbox_top(spr) return D.sprite_meta(spr).bbox[2] end
function sprite_get_bbox_right(spr) return D.sprite_meta(spr).bbox[3] end
function sprite_get_bbox_bottom(spr) return D.sprite_meta(spr).bbox[4] end
function asset_get_index(name) return name end

return D
