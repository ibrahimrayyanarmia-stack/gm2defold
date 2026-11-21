#!/usr/bin/env python3
"""
gm2defold.py - convert a GameMaker (2.3+/2024, .yyp) project into a Defold project
that runs on the "gm" compatibility runtime (template/gm/*.lua).

What it does automatically:
  * copies every sprite frame to assets/img/<sprite>_<frame>.png and builds a paged atlas
  * copies .ogg/.wav sounds and creates one sound component per sound (mp3 is NOT supported
    by Defold - those are reported and skipped unless an .ogg/.wav with the same name exists
    next to the mp3 or in --extra-sounds)
  * writes game/meta.lua (sprites, objects, fonts, sounds, rooms, room order, game speed)
  * writes stub Lua files for every object / script / creation code containing the
    original GML as comments (only when the stub does not exist yet - never overwrites ported code
    unless --force-stubs)
  * writes game.project, input binding, main collection, factories, material, font.

Usage:
  python3 gm2defold.py <GameMaker project dir> <Defold output dir> [--title T]
                        [--width W --height H] [--page 4096] [--force-stubs]
"""
import json, os, re, shutil, struct, sys, zlib, argparse, math

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "template")


# ---------------------------------------------------------------- helpers
def load_yy(path):
    with open(path, encoding="utf-8-sig") as f:
        s = f.read()
    s = re.sub(r",(\s*[}\]])", r"\1", s)
    return json.loads(s)


def lua_str(s):
    s = str(s)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "") + '"'


def lua_val(v, indent=""):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        if isinstance(v, float) and v.is_integer():
            return str(int(v))
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        inner = ", ".join(lua_val(x, indent + "  ") for x in v)
        return "{" + inner + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        parts = []
        for k, x in v.items():
            key = k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) and k not in LUA_KEYWORDS else "[" + lua_str(k) + "]"
            parts.append(indent + "  " + key + " = " + lua_val(x, indent + "  "))
        return "{\n" + ",\n".join(parts) + "\n" + indent + "}"
    raise TypeError(type(v))


LUA_KEYWORDS = set("and break do else elseif end false for function goto if in local nil not or repeat return then true until while".split())


def long_comment(text):
    lvl = 1
    while ("]" + "=" * lvl + "]") in text:
        lvl += 1
    eq = "=" * lvl
    return "--[" + eq + "[\n" + text.rstrip() + "\n]" + eq + "]"


def png_size(path):
    with open(path, "rb") as f:
        b = f.read(24)
    return struct.unpack(">II", b[16:24])


def write_png(path, w, h, pixel_fn):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel_fn(x, y))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def gm_colour(c):
    """GM ABGR uint32 -> (bgr int, alpha 0..1)"""
    if isinstance(c, str):
        c = c.strip()
        if c.startswith("$"):
            c = int(c[1:], 16)
        elif c.startswith("#"):
            # #RRGGBB
            v = int(c[1:7], 16)
            return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF), 1.0
        else:
            try:
                c = int(float(c))
            except ValueError:
                return 0xFFFFFF, 1.0
    c = int(c) & 0xFFFFFFFF
    a = ((c >> 24) & 0xFF) / 255.0
    return c & 0xFFFFFF, round(a, 4)


def prop_value(vartype, value):
    """Convert a GM Variable Definition value (string) to a python value. Returns (value, is_expression)."""
    s = "" if value is None else str(value)
    if vartype in (0, 1):
        try:
            f = float(s)
            return (int(f) if f.is_integer() else f), False
        except ValueError:
            return s, True
    if vartype == 2:
        if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
            s = s[1:-1]
        return s, False
    if vartype == 3:
        return s.strip().lower() in ("true", "1"), False
    if vartype == 5:
        return s, False
    if vartype == 7:
        return gm_colour(s)[0], False
    # expression / list
    t = s.strip()
    if t.lower() in ("true", "false"):
        return t.lower() == "true", False
    if t.lower() in ("undefined", "noone", ""):
        return None, t.lower() not in ("undefined", "")
    try:
        f = float(t)
        return (int(f) if f.is_integer() else f), False
    except ValueError:
        pass
    if len(t) >= 2 and t[0] == t[-1] and t[0] == '"':
        return t[1:-1], False
    return t, True


EVENT_NAMES = {
    (0, 0): "create", (1, 0): "destroy", (12, 0): "cleanup",
    (3, 0): "step", (3, 1): "step_begin", (3, 2): "step_end",
    (8, 0): "draw", (8, 64): "draw_gui", (8, 72): "draw_begin", (8, 73): "draw_end",
    (8, 74): "draw_gui_begin", (8, 75): "draw_gui_end", (8, 76): "draw_pre", (8, 77): "draw_post",
}
MOUSE_EVENTS = {0: "mouse_left_down", 1: "mouse_right_down", 2: "mouse_middle_down", 3: "mouse_no_button",
                4: "mouse_left_pressed", 5: "mouse_right_pressed", 6: "mouse_middle_pressed",
                7: "mouse_left_released", 8: "mouse_right_released", 9: "mouse_middle_released",
                10: "mouse_enter", 11: "mouse_leave",
                50: "global_left_down", 51: "global_right_down", 52: "global_middle_down",
                53: "global_left_pressed", 54: "global_right_pressed", 55: "global_middle_pressed",
                56: "global_left_released", 57: "global_right_released", 58: "global_middle_released",
                60: "mouse_wheel_up", 61: "mouse_wheel_down"}
OTHER_EVENTS = {0: "outside_room", 1: "intersect_boundary", 2: "game_start", 3: "game_end",
                4: "room_start", 5: "room_end", 7: "animation_end", 8: "animation_update", 9: "animation_event"}
for i in range(16):
    OTHER_EVENTS[10 + i] = "user%d" % i
    OTHER_EVENTS[40 + i] = "outside_view%d" % i


def event_name_from_file(fname):
    base = fname[:-4]
    m = re.match(r"^(Create|Destroy|CleanUp|Step|Draw|Alarm|Mouse|Other|Keyboard|KeyPress|KeyRelease|Collision)_(.+)$", base)
    if not m:
        return None, base
    kind, num = m.group(1), m.group(2)
    if kind == "Collision":
        return ("collision", num), base
    n = int(num) if num.isdigit() else None
    if kind == "Create": return "create", base
    if kind == "Destroy": return "destroy", base
    if kind == "CleanUp": return "cleanup", base
    if kind == "Step": return {0: "step", 1: "step_begin", 2: "step_end"}.get(n, base), base
    if kind == "Draw": return EVENT_NAMES.get((8, n), "draw_%s" % num), base
    if kind == "Alarm": return "alarm%d" % n, base
    if kind == "Mouse": return MOUSE_EVENTS.get(n, "mouse_%s" % num), base
    if kind == "Other": return OTHER_EVENTS.get(n, "other_%s" % num), base
    if kind == "Keyboard": return "key_down_%s" % num, base
    if kind == "KeyPress": return "key_pressed_%s" % num, base
    if kind == "KeyRelease": return "key_released_%s" % num, base
    return None, base


# ---------------------------------------------------------------- Defold text formats
def pb_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def embedded(id_, type_, data):
    return "embedded_components {\n  id: %s\n  type: %s\n  data: %s\n}\n" % (pb_str(id_), pb_str(type_), pb_str(data))


def write(path, text, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode, encoding="utf-8", newline="\n") as f:
        f.write(text)


KEYMAP = [  # (Defold input, GM keycode)
    ("KEY_SPACE", 32), ("KEY_ENTER", 13), ("KEY_KP_ENTER", 13), ("KEY_ESC", 27), ("KEY_TAB", 9), ("KEY_BACKSPACE", 8),
    ("KEY_LEFT", 37), ("KEY_UP", 38), ("KEY_RIGHT", 39), ("KEY_DOWN", 40),
    ("KEY_LSHIFT", 160), ("KEY_RSHIFT", 161), ("KEY_LCTRL", 162), ("KEY_RCTRL", 163), ("KEY_LALT", 164), ("KEY_RALT", 165),
    ("KEY_INSERT", 45), ("KEY_DEL", 46), ("KEY_HOME", 36), ("KEY_END", 35), ("KEY_PAGEUP", 33), ("KEY_PAGEDOWN", 34),
    ("KEY_PAUSE", 19), ("KEY_CAPS_LOCK", 20),
    ("KEY_KP_ADD", 107), ("KEY_KP_SUBTRACT", 109), ("KEY_KP_MULTIPLY", 106), ("KEY_KP_DIVIDE", 111), ("KEY_KP_DECIMAL", 110),
    ("KEY_COMMA", 188), ("KEY_PERIOD", 190), ("KEY_MINUS", 189), ("KEY_EQUALS", 187), ("KEY_SLASH", 191),
    ("KEY_SEMICOLON", 186), ("KEY_QUOTE", 222), ("KEY_LBRACKET", 219), ("KEY_RBRACKET", 221), ("KEY_BACKSLASH", 220), ("KEY_BACKQUOTE", 192),
]
KEYMAP += [("KEY_%s" % chr(c), c) for c in range(65, 91)]
KEYMAP += [("KEY_%d" % d, 48 + d) for d in range(10)]
KEYMAP += [("KEY_KP_%d" % d, 96 + d) for d in range(10)]
KEYMAP += [("KEY_F%d" % i, 111 + i) for i in range(1, 13)]


def input_binding():
    out = []
    for k, code in KEYMAP:
        out.append('key_trigger {\n  input: %s\n  action: "k%d"\n}\n' % (k, code))
    for m, a in [("MOUSE_BUTTON_LEFT", "mb1"), ("MOUSE_BUTTON_RIGHT", "mb2"), ("MOUSE_BUTTON_MIDDLE", "mb3"),
                 ("MOUSE_WHEEL_UP", "wheel_up"), ("MOUSE_WHEEL_DOWN", "wheel_down")]:
        out.append('mouse_trigger {\n  input: %s\n  action: "%s"\n}\n' % (m, a))
    out.append('text_trigger {\n  input: TEXT\n  action: "text"\n}\n')
    return "".join(out)


PIVOTS = ["NW", "N", "NE", "W", "CENTER", "E", "SW", "S", "SE"]


def label_go(pivot):
    data = ("size {\n  x: 128.0\n  y: 32.0\n  z: 0.0\n  w: 0.0\n}\n"
            "color {\n  x: 1.0\n  y: 1.0\n  z: 1.0\n  w: 1.0\n}\n"
            "outline {\n  x: 0.0\n  y: 0.0\n  z: 0.0\n  w: 0.0\n}\n"
            "shadow {\n  x: 0.0\n  y: 0.0\n  z: 0.0\n  w: 0.0\n}\n"
            "leading: 1.0\ntracking: 0.0\npivot: PIVOT_%s\nblend_mode: BLEND_MODE_ALPHA\nline_break: false\n"
            "text: \"\"\nfont: \"/main/gm.font\"\nmaterial: \"/builtins/fonts/label-df.material\"\n") % pivot
    return embedded("label", "label", data)


def sprite_go():
    data = ('default_animation: "__px"\nmaterial: "/main/gm_sprite.material"\nblend_mode: BLEND_MODE_ALPHA\n'
            'textures {\n  sampler: "texture_sampler"\n  texture: "/assets/main.atlas"\n}\n')
    return embedded("sprite", "sprite", data)


def main_collection(sounds):
    comps = 'components {\n  id: "script"\n  component: "/main/main.script"\n}\n'
    comps += embedded("f_spr", "factory", 'prototype: "/main/spr.go"\n')
    for p in PIVOTS:
        comps += embedded("f_lbl_" + p.lower(), "factory", 'prototype: "/main/lbl_%s.go"\n' % p.lower())
    audio = ""
    for name, path in sounds:
        audio += embedded(name, "sound", 'sound: "%s"\nlooping: 0\ngroup: "master"\ngain: 1.0\n' % path)
    return ('name: "main"\nscale_along_z: 0\n'
            'embedded_instances {\n  id: "main"\n  data: %s\n}\n'
            'embedded_instances {\n  id: "audio"\n  data: %s\n}\n') % (pb_str(comps), pb_str(audio))


# ---------------------------------------------------------------- main conversion
def convert(src, dst, args):
    yyps = [f for f in os.listdir(src) if f.endswith(".yyp")]
    if not yyps:
        sys.exit("no .yyp in " + src)
    yyp = load_yy(os.path.join(src, yyps[0]))
    proj_name = yyp.get("name") or yyps[0][:-4]
    title = args.title or proj_name
    os.makedirs(dst, exist_ok=True)
    report = []

    res = [r["id"]["path"] for r in yyp.get("resources", [])]
    def of_kind(kind):
        return sorted(p for p in res if p.startswith(kind + "/") and os.path.exists(os.path.join(src, p)))

    # ---- options
    game_speed = 60
    opt = os.path.join(src, "options", "main", "options_main.yy")
    if os.path.exists(opt):
        o = load_yy(opt)
        game_speed = o.get("option_game_speed", 60) or 60

    # ---- sprites
    img_dir = os.path.join(dst, "assets", "img")
    if os.path.isdir(img_dir):
        shutil.rmtree(img_dir)
    os.makedirs(img_dir)
    sprites = {}
    atlas_images = []
    total_px = 0
    max_dim = 0
    for p in of_kind("sprites"):
        y = load_yy(os.path.join(src, p))
        name = y["name"]
        sdir = os.path.dirname(os.path.join(src, p))
        seq = y.get("sequence") or {}
        frames = [f["name"] for f in y.get("frames", [])]
        w, h = y.get("width", 1), y.get("height", 1)
        n = 0
        for i, fr in enumerate(frames):
            fp = os.path.join(sdir, fr + ".png")
            if not os.path.exists(fp):
                report.append("sprite %s frame %d missing png" % (name, i))
                continue
            out = os.path.join(img_dir, "%s_%d.png" % (name, i))
            shutil.copyfile(fp, out)
            fw, fh = png_size(fp)
            total_px += fw * fh
            max_dim = max(max_dim, fw, fh)
            atlas_images.append("/assets/img/%s_%d.png" % (name, i))
            n += 1
        sprites[name] = {
            "w": w, "h": h, "xo": seq.get("xorigin", 0), "yo": seq.get("yorigin", 0), "n": n,
            "speed": seq.get("playbackSpeed", 1.0), "speed_type": seq.get("playbackSpeedType", 0),
            "bbox": [y.get("bbox_left", 0), y.get("bbox_top", 0), y.get("bbox_right", w - 1), y.get("bbox_bottom", h - 1)],
        }
    # extra (generated) sprites: <dir>/sprites.json = {name: {xo, yo, frames: [png...], speed, speed_type, bbox}}
    if args.extra_sprites:
        sj = os.path.join(args.extra_sprites, "sprites.json")
        for name, d in json.load(open(sj)).items():
            n = 0
            w = h = 1
            for i, fr in enumerate(d["frames"]):
                fp = os.path.join(args.extra_sprites, fr)
                shutil.copyfile(fp, os.path.join(img_dir, "%s_%d.png" % (name, i)))
                w, h = png_size(fp)
                total_px += w * h
                max_dim = max(max_dim, w, h)
                atlas_images.append("/assets/img/%s_%d.png" % (name, i))
                n += 1
            sprites[name] = {"w": w, "h": h, "xo": d.get("xo", 0), "yo": d.get("yo", 0), "n": n,
                             "speed": d.get("speed", 1), "speed_type": d.get("speed_type", 1),
                             "bbox": d.get("bbox", [0, 0, w - 1, h - 1])}
    # builtin helper images
    write_png(os.path.join(img_dir, "__px.png"), 4, 4, lambda x, y: (255, 255, 255, 255))
    def disc(x, y, R=32):
        d = math.hypot(x + 0.5 - R, y + 0.5 - R)
        a = max(0.0, min(1.0, R - d))
        return (255, 255, 255, int(a * 255))
    write_png(os.path.join(img_dir, "__disc.png"), 64, 64, disc)
    atlas_images += ["/assets/img/__px.png", "/assets/img/__disc.png"]

    page = args.page
    while page < max_dim + 8:
        page *= 2
    pages = max(1, int(math.ceil(total_px * 1.35 / (page * page))) + 1)
    def trim_mode(img):
        if not args.trim:
            return "SPRITE_TRIM_MODE_OFF"
        w, h = png_size(os.path.join(dst, img.lstrip("/")))
        return "SPRITE_TRIM_MODE_8" if max(w, h) >= 256 else "SPRITE_TRIM_MODE_OFF"
    atlas = "".join('images {\n  image: "%s"\n  sprite_trim_mode: %s\n}\n' % (i, trim_mode(i)) for i in atlas_images)
    atlas += "margin: 0\nextrude_borders: 2\ninner_padding: 0\nmax_page_width: %d\nmax_page_height: %d\n" % (page, page)
    write(os.path.join(dst, "assets", "main.atlas"), atlas)
    report.append("atlas: %d images, %.1f Mpx, page %d, est. pages %d" % (len(atlas_images), total_px / 1e6, page, pages))

    # ---- sounds
    snd_dir = os.path.join(dst, "sounds")
    os.makedirs(snd_dir, exist_ok=True)
    sounds_meta, sound_comps = {}, []
    for p in of_kind("sounds"):
        y = load_yy(os.path.join(src, p))
        name = y["name"]
        sdir = os.path.dirname(os.path.join(src, p))
        sf = y.get("soundFile", "")
        base, ext = os.path.splitext(sf)
        chosen = None
        for cand in [os.path.join(sdir, base + ".ogg"), os.path.join(sdir, base + ".wav"),
                     os.path.join(args.extra_sounds or "", name + ".ogg"), os.path.join(args.extra_sounds or "", name + ".wav"),
                     os.path.join(sdir, sf)]:
            if cand and os.path.exists(cand) and os.path.splitext(cand)[1].lower() in (".ogg", ".wav"):
                chosen = cand
                break
        if not chosen:
            report.append("SOUND SKIPPED (unsupported format %s, convert to .ogg): %s" % (ext, name))
            sounds_meta[name] = {"missing": True, "volume": y.get("volume", 1.0), "duration": y.get("duration", 0)}
            continue
        oext = os.path.splitext(chosen)[1].lower()
        shutil.copyfile(chosen, os.path.join(snd_dir, name + oext))
        sounds_meta[name] = {"volume": y.get("volume", 1.0), "duration": y.get("duration", 0)}
        sound_comps.append((name, "/sounds/%s%s" % (name, oext)))

    # extra sounds: every .wav/.ogg in --extra-sounds that is not a project sound is added too
    if args.extra_sounds and os.path.isdir(args.extra_sounds):
        for f in sorted(os.listdir(args.extra_sounds)):
            stem, ext = os.path.splitext(f)
            if ext.lower() in (".wav", ".ogg") and stem not in sounds_meta:
                shutil.copyfile(os.path.join(args.extra_sounds, f), os.path.join(snd_dir, stem + ext.lower()))
                sounds_meta[stem] = {"volume": 1.0, "duration": 0}
                sound_comps.append((stem, "/sounds/%s%s" % (stem, ext.lower())))

    # ---- fonts
    fonts = {}
    for p in of_kind("fonts"):
        y = load_yy(os.path.join(src, p))
        fonts[y["name"]] = {"size": y.get("size", 12), "family": y.get("fontName", ""), "bold": y.get("bold", False)}

    # ---- objects
    objects = {}
    obj_dir = os.path.join(dst, "game", "objects")
    os.makedirs(obj_dir, exist_ok=True)
    for p in of_kind("objects"):
        y = load_yy(os.path.join(src, p))
        name = y["name"]
        odir = os.path.dirname(os.path.join(src, p))
        props, exprs = {}, []
        for pr in y.get("properties", []):
            v, is_expr = prop_value(pr.get("varType", 0), pr.get("value"))
            props[pr["name"]] = v
            if is_expr:
                exprs.append("%s = %s" % (pr["name"], pr.get("value")))
        over = {}
        for pr in y.get("overriddenProperties", []):
            over[pr["propertyId"]["name"]] = pr.get("value")
        objects[name] = {
            "sprite": (y.get("spriteId") or {}).get("name"),
            "mask": (y.get("spriteMaskId") or {}).get("name"),
            "parent": (y.get("parentObjectId") or {}).get("name"),
            "visible": y.get("visible", True), "persistent": y.get("persistent", False), "solid": y.get("solid", False),
            "props": props,
        }
        if over:
            objects[name]["overridden"] = {k: prop_value(5 if v is None else 4, v)[0] for k, v in over.items()}
        stub = os.path.join(obj_dir, name + ".lua")
        if os.path.exists(stub) and not args.force_stubs:
            continue
        lines = ["-- Port of GameMaker object %s" % name,
                 "-- parent: %s | sprite: %s | visible: %s | persistent: %s" % (
                     objects[name]["parent"], objects[name]["sprite"], objects[name]["visible"], objects[name]["persistent"])]
        if props:
            lines.append("-- Variable Definitions (already applied before create): " + ", ".join(sorted(props)))
        if exprs:
            lines.append("-- WARNING expression-valued Variable Definitions (meta has the raw string, port them in create): " + "; ".join(exprs))
        lines += ["local O = %s" % name, ""]
        files = sorted(f for f in os.listdir(odir) if f.endswith(".gml"))
        for f in files:
            ev, base = event_name_from_file(f)
            gml = open(os.path.join(odir, f), encoding="utf-8-sig", errors="replace").read()
            lines.append(long_comment("%s.gml\n%s" % (base, gml)))
            if isinstance(ev, tuple):
                lines.append("O.collision = O.collision or {}")
                lines.append("O.collision[%s] = function(self, other)\nend\n" % lua_str(ev[1]))
            elif ev:
                lines.append("function O.%s(self)\nend\n" % ev)
            else:
                lines.append("-- (unknown event file %s)\n" % f)
        # events that exist in the object but have no .gml file (e.g. an empty Draw event that
        # suppresses the default draw_self) still need an (empty) handler
        have = set(event_name_from_file(f)[0] for f in files if not isinstance(event_name_from_file(f)[0], tuple))
        for e in y.get("eventList", []):
            et, en = e.get("eventType"), e.get("eventNum")
            name_ = EVENT_NAMES.get((et, en)) or (et == 2 and "alarm%d" % en) or (et == 6 and MOUSE_EVENTS.get(en)) or (et == 7 and OTHER_EVENTS.get(en))
            if name_ and name_ not in have:
                lines.append("-- (empty %s event in GameMaker: kept so it overrides the parent / default draw)" % name_)
                lines.append("function O.%s(self)\nend\n" % name_)
        lines.append("return O\n")
        write(stub, "\n".join(lines))

    # ---- scripts
    scr_dir = os.path.join(dst, "game", "scripts")
    os.makedirs(scr_dir, exist_ok=True)
    scripts = []
    for p in of_kind("scripts"):
        name = os.path.basename(os.path.dirname(p))
        gpath = os.path.join(src, os.path.dirname(p), name + ".gml")
        scripts.append(name)
        stub = os.path.join(scr_dir, name + ".lua")
        if os.path.exists(stub) and not args.force_stubs:
            continue
        gml = open(gpath, encoding="utf-8-sig", errors="replace").read() if os.path.exists(gpath) else ""
        write(stub, "-- Port of GameMaker script %s\n%s\n\n" % (name, long_comment(gml)))

    # ---- rooms
    rooms = {}
    room_code_parts = []
    def parse_layers(layers, out):
        for L in layers:
            t = L.get("$GMRInstanceLayer") is not None and "instances" or \
                L.get("$GMRBackgroundLayer") is not None and "background" or \
                L.get("$GMRAssetLayer") is not None and "assets" or \
                L.get("$GMRTileLayer") is not None and "tiles" or \
                L.get("$GMRPathLayer") is not None and "path" or "folder"
            d = {"name": L["name"], "depth": L.get("depth", 0), "type": t, "visible": L.get("visible", True)}
            if t == "instances":
                insts = []
                for i in L.get("instances", []):
                    col, a = gm_colour(i.get("colour", 4294967295))
                    inst = {"obj": i["objectId"]["name"], "name": i["name"], "x": i.get("x", 0), "y": i.get("y", 0),
                            "sx": i.get("scaleX", 1), "sy": i.get("scaleY", 1), "rot": i.get("rotation", 0),
                            "colour": col, "alpha": a, "frame": i.get("imageIndex", 0), "speed": i.get("imageSpeed", 1)}
                    pr = {}
                    for p_ in i.get("properties", []):
                        pname = p_["propertyId"]["name"]
                        ptype = None
                        # find declared type through object/parents
                        on = i["objectId"]["name"]
                        pr[pname] = p_.get("value")
                    if pr:
                        inst["props_raw"] = pr
                    if i.get("hasCreationCode"):
                        inst["code"] = True
                    insts.append(inst)
                d["instances"] = insts
            elif t == "background":
                col, a = gm_colour(L.get("colour", 4294967295))
                d.update({"sprite": (L.get("spriteId") or {}).get("name"), "colour": col, "alpha": a,
                          "htiled": L.get("htiled", False), "vtiled": L.get("vtiled", False), "stretch": L.get("stretch", False),
                          "x": L.get("x", 0), "y": L.get("y", 0), "hspeed": L.get("hspeed", 0), "vspeed": L.get("vspeed", 0),
                          "frame": 0, "anim_fps": L.get("animationFPS", 0), "anim_type": L.get("animationSpeedType", 0)})
            elif t == "assets":
                assets = []
                for a_ in L.get("assets", []):
                    if a_.get("$GMRSpriteGraphic") is None and a_.get("resourceType") != "GMRSpriteGraphic":
                        continue
                    col, al = gm_colour(a_.get("colour", 4294967295))
                    assets.append({"sprite": a_["spriteId"]["name"], "x": a_.get("x", 0), "y": a_.get("y", 0),
                                   "sx": a_.get("scaleX", 1), "sy": a_.get("scaleY", 1), "rot": a_.get("rotation", 0),
                                   "colour": col, "alpha": al, "frame": a_.get("headPosition", 0), "speed": a_.get("animationSpeed", 1)})
                d["assets"] = assets
            elif t == "tiles":
                report.append("room layer %s is a TILE layer - not converted automatically" % L["name"])
            out.append(d)
            if L.get("layers"):
                parse_layers(L["layers"], out)

    order = [n["roomId"]["name"] for n in yyp.get("RoomOrderNodes", [])]
    for p in of_kind("rooms"):
        y = load_yy(os.path.join(src, p))
        name = y["name"]
        rdir = os.path.dirname(os.path.join(src, p))
        rs = y.get("roomSettings", {})
        vs = y.get("viewSettings", {})
        layers = []
        parse_layers(y.get("layers", []), layers)
        views = []
        for v in y.get("views", []):
            views.append({"visible": v.get("visible", False), "x": v.get("xview", 0), "y": v.get("yview", 0),
                          "w": v.get("wview", 0), "h": v.get("hview", 0), "wport": v.get("wport", 0), "hport": v.get("hport", 0),
                          "follow": (v.get("objectId") or {}).get("name"), "hborder": v.get("hborder", 0), "vborder": v.get("vborder", 0),
                          "hspeed": v.get("hspeed", -1), "vspeed": v.get("vspeed", -1)})
        rooms[name] = {"width": rs.get("Width", 1366), "height": rs.get("Height", 768), "persistent": rs.get("persistent", False),
                       "views_enabled": vs.get("enableViews", False), "views": views, "layers": layers,
                       "creation_code": bool(y.get("creationCodeFile"))}
        # creation code
        part = []
        cc = os.path.join(rdir, "RoomCreationCode.gml")
        if os.path.exists(cc):
            part.append(long_comment("Room creation code %s\n%s" % (name, open(cc, encoding="utf-8-sig", errors="replace").read())))
            part.append("C[%s] = function()\nend\n" % lua_str(name))
        for L in layers:
            for inst in L.get("instances", []):
                if inst.get("code"):
                    f = os.path.join(rdir, "InstanceCreationCode_%s.gml" % inst["name"])
                    if os.path.exists(f):
                        part.append(long_comment("Instance creation code %s (%s in %s)\n%s" % (
                            inst["name"], inst["obj"], name, open(f, encoding="utf-8-sig", errors="replace").read())))
                        part.append("C[%s] = function(self)\nend\n" % lua_str(inst["name"]))
        if part:
            room_code_parts.append("\n".join(part))
    order = [r for r in order if r in rooms] + sorted(r for r in rooms if r not in order)

    # resolve instance property overrides to typed values using object definitions (incl. parents)
    def prop_type(obj, pname):
        while obj:
            yp = os.path.join(src, "objects", obj, obj + ".yy")
            if not os.path.exists(yp):
                return 4
            y = load_yy(yp)
            for pr in y.get("properties", []):
                if pr["name"] == pname:
                    return pr.get("varType", 4)
            obj = (y.get("parentObjectId") or {}).get("name")
        return 4
    for r in rooms.values():
        for L in r["layers"]:
            for inst in L.get("instances", []):
                raw = inst.pop("props_raw", None)
                if raw:
                    inst["props"] = {k: prop_value(prop_type(inst["obj"], k), v)[0] for k, v in raw.items()}

    code_path = os.path.join(dst, "game", "room_code.lua")
    if not os.path.exists(code_path) or args.force_stubs:
        write(code_path, "-- Room / instance creation code (ported from GML).\n"
                         "-- C[room_name] = function() end            : room creation code (runs after instance creates)\n"
                         "-- C[instance_name] = function(self) end    : instance creation code (runs right after that instance's create)\n"
                         "local C = {}\n\n" + "\n\n".join(room_code_parts) + "\n\nreturn C\n")

    # ---- display size
    first = rooms[order[0]] if order else {"width": 1366, "height": 768, "views_enabled": False, "views": []}
    dw, dh = first["width"], first["height"]
    if first.get("views_enabled"):
        for v in first["views"]:
            if v["visible"]:
                dw, dh = v["wport"] or v["w"], v["hport"] or v["h"]
                break
    dw, dh = args.width or dw, args.height or dh

    # ---- meta.lua
    meta = {"title": title, "game_speed": game_speed, "display_width": dw, "display_height": dh,
            "room_order": order, "sprites": sprites, "objects": objects, "fonts": fonts, "sounds": sounds_meta,
            "rooms": rooms, "scripts": scripts}
    write(os.path.join(dst, "game", "meta.lua"), "-- GENERATED by gm2defold.py - do not edit by hand (re-run the converter)\nreturn " + lua_val(meta) + "\n")

    # ---- runtime + engine files
    tdst = os.path.join(dst, "gm")
    if os.path.isdir(tdst):
        shutil.rmtree(tdst)
    shutil.copytree(os.path.join(TEMPLATE, "gm"), tdst)
    os.makedirs(os.path.join(dst, "main"), exist_ok=True)
    for f in os.listdir(os.path.join(TEMPLATE, "main")):
        shutil.copyfile(os.path.join(TEMPLATE, "main", f), os.path.join(dst, "main", f))
    mat = open(os.path.join(TEMPLATE, "main", "gm_sprite.material")).read().replace("max_page_count: 4", "max_page_count: %d" % max(4, pages + 2))
    write(os.path.join(dst, "main", "gm_sprite.material"), mat)
    write(os.path.join(dst, "main", "spr.go"), sprite_go())
    for p in PIVOTS:
        write(os.path.join(dst, "main", "lbl_%s.go" % p.lower()), label_go(p))
    write(os.path.join(dst, "main", "main.collection"), main_collection(sound_comps))
    write(os.path.join(dst, "input", "game.input_binding"), input_binding())
    game_main = os.path.join(dst, "game", "main.lua")
    if not os.path.exists(game_main) or args.force_stubs:
        req = "\n".join('require "game.scripts.%s"' % s for s in scripts)
        reqo = "\n".join('require "game.objects.%s"' % o for o in sorted(objects))
        write(game_main, "-- Game entry: load scripts first, then objects, then room/instance creation code.\n%s\n\n%s\n\nrequire \"game.room_code\"\n" % (req, reqo))
    gp = open(os.path.join(TEMPLATE, "game.project")).read()
    gp = gp.replace("{TITLE}", title).replace("{W}", str(dw)).replace("{H}", str(dh)).replace("{FPS}", str(int(game_speed)))
    write(os.path.join(dst, "game.project"), gp)
    write(os.path.join(dst, ".gitignore"), "/.internal\n/build\n.externalToolBuilders\n.DS_Store\nThumbs.db\n")
    print("\n".join(report))
    print("converted %s -> %s (%d sprites, %d objects, %d rooms, %d sounds, display %dx%d)" % (
        proj_name, dst, len(sprites), len(objects), len(rooms), len(sound_comps), dw, dh))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--title")
    ap.add_argument("--width", type=int)
    ap.add_argument("--height", type=int)
    ap.add_argument("--page", type=int, default=2048)
    ap.add_argument("--extra-sounds", help="dir with <sound>.ogg/.wav replacements (e.g. converted mp3s) or extra generated sounds")
    ap.add_argument("--extra-sprites", help="dir with sprites.json + pngs for sprites generated outside GameMaker")
    ap.add_argument("--force-stubs", action="store_true")
    ap.add_argument("--trim", action="store_true", help="trim transparent borders of big images in the atlas (saves texture memory)")
    convert(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), ap.parse_args())
