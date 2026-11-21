# gm2defold

**Convert GameMaker projects to Defold.**

gm2defold reads a GameMaker 2.3+ / 2024 project (`.yyp`) and produces a Defold project that runs
on a small GameMaker-compatible Lua runtime. The runtime keeps the GML function names, the event
model and the room semantics, so ported code looks almost the same as the original.

> [!IMPORTANT]
> **Project status: asset converter + runtime.** gm2defold converts all assets and metadata
> automatically. It does not translate GML to Lua yet: it writes Lua stubs that contain the
> original GML, and you port the logic by hand.
> An automatic GML→Lua transpiler is planned.

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Project layout](#project-layout)
- [Supported features](#supported-features)
- [Testing your port](#testing-your-port)
- [Roadmap](#roadmap)
- [Contributing](#contributing)

---

## Features

- **Sprites** are packed into paged texture atlases. Origins, bounding boxes, animation speed and
  frame count are kept. `--trim` crops transparent borders.
- **Sounds** become Defold sound components (`.ogg` / `.wav`).
- **Rooms** carry over every instance, layer, view, creation code, the room order and the game speed.
- **Objects** keep their parent chain, sprite, visibility, persistence and Variable Definitions,
  including per-instance overrides.
- **Fonts** map to a built-in monospace font scaled to the GameMaker point size.
- **Input** gets a full keyboard and mouse binding with GameMaker key codes.
- **The runtime** (`template/gm/`) has about 2,500 lines of Lua implementing instances, events,
  alarms, collisions, motion, drawing, text, views, audio, input, ds_* structures, arrays, strings
  and INI saving, all under the GML names.
- **Re-running the converter is safe.** Generated files are refreshed, but stubs you have already
  ported are never overwritten.
- **There is a headless build and test loop.** You can build, run, script input and take
  screenshots from the command line.

## Requirements

| Requirement | Notes |
|---|---|
| Python 3.8+ | Standard library only, nothing to install with pip. |
| [Defold](https://defold.com) | The editor install provides `bob` (the builder) and its bundled JDK. |
| Windows + WSL | `build.sh` and `run.sh` are bash scripts that call the Windows Defold install and engine. |

> [!NOTE]
> `build.sh` expects Defold at `C:\defold` (`/mnt/c/defold`) and points to a specific
> `packages/defold-<sha>.jar` and JDK version. Change the `J=` and `JAR=` lines if your install is
> somewhere else or is a different version.

## Quick start

```bash
cd gm2defold

# 1. Convert
python3 gm2defold.py "/path/to/MyGame" ../MyGameDefold --title "My Game"

# 2. Port the GML in ../MyGameDefold/game/**/*.lua

# 3. Build (Lua syntax errors show up here)
./build.sh ../MyGameDefold

# 4. Run for 8 seconds and take a screenshot
./run.sh ../MyGameDefold 8 /tmp/mygame
```

You can also open `../MyGameDefold/game.project` in the Defold editor and use **Project ▸ Build**.

## Usage

```
python3 gm2defold.py <gamemaker_project_dir> <defold_output_dir> [options]
```

| Option | Description |
|---|---|
| `--title T` | Window and project title. |
| `--width W`, `--height H` | Override the display size (by default it comes from the first room's view or size). |
| `--page N` | Atlas page size in pixels (default `2048`). |
| `--trim` | Trim transparent borders of large images in the atlas to save texture memory. |
| `--extra-sounds DIR` | `<name>.wav/.ogg` files that replace project sounds with the same name (for example converted mp3s). Any other files there are added as extra sounds. |
| `--extra-sprites DIR` | Sprites made outside GameMaker. `DIR/sprites.json` describes them (see below). |
| `--force-stubs` | Regenerate the object and script stubs. **This overwrites ported code.** |

`sprites.json` format for `--extra-sprites`:

```json
{
  "spr_enemy": { "xo": 8, "yo": 8, "frames": ["enemy_0.png", "enemy_1.png"],
                 "speed": 1, "speed_type": 1, "bbox": [0, 0, 15, 15] }
}
```

`speed_type` is `1` for frames per game frame and `0` for frames per second.

### Build and run scripts

```bash
./build.sh <project_dir> [extra bob args]
./run.sh   <project_dir> [seconds=6] [screenshot_prefix] [autotest_script]
```

`run.sh` starts the built game with the bundled Windows engine and prints the engine log (Lua
errors and `print` output). It saves `<prefix>_<t>s.png` screenshots at the times listed in
`SHOT_TIMES` (for example `SHOT_TIMES="2 5 7"`). Each project runs under its own process name, so
several games can run at the same time.

## How it works

```
 GameMaker project (.yyp)                      Defold project
 ├── sprites/   ─────────────────────────────▶ assets/  (paged atlas)
 ├── sounds/    ─────────────────────────────▶ sounds/  (sound components)
 ├── rooms/, objects/, fonts/  (metadata) ───▶ game/meta.lua
 ├── objects/*.gml, scripts/*.gml  ──────────▶ game/objects/*.lua, game/scripts/*.lua   (stubs)
 └── room / instance creation code ──────────▶ game/room_code.lua                       (stubs)
                                               gm/        GameMaker-compatible runtime
                                               main/      collection, material, font, main.script
                                               game.project, input/
```

Every object becomes a global Lua table, and every event becomes a function on it:

```lua
-- game/objects/obj_player.lua
local O = obj_player

--[=[
Step_0.gml
x += (keyboard_check(vk_right) - keyboard_check(vk_left)) * spd;
]=]
function O.step(self)
	self.x = self.x + (num(keyboard_check(vk_right)) - num(keyboard_check(vk_left))) * self.spd
end

return O
```

The runtime runs the GameMaker event order every frame: begin step, alarms, step, collisions,
end step, then the draw events. It inherits events through parents, calls `draw_self()` when an
object has no draw event, and handles room transitions and persistent instances.

## Project layout

```
gm2defold/
├── gm2defold.py        Converter
├── build.sh            Headless build with bob
├── run.sh              Run, log, screenshot, scripted input
├── template/
│   ├── gm/             Runtime: gm.lua, draw.lua, audio.lua, lib.lua
│   ├── main/           main.script, sprite material/shaders, font
│   └── game.project
├── engine/             Windows engine binaries + screenshot helper
├── tools/
│   └── mp3towav.ps1    mp3 → wav (Defold has no mp3 support)
```

## Supported features

| Area | Status |
|---|---|
| Objects, parents, `event_inherited`, user events | ✅ |
| Create / Step / Draw / Alarm / Destroy / Room & Game events | ✅ |
| Mouse, keyboard and collision events | ✅ |
| `with`, `other`, `instance_*`, `place_meeting`, `collision_*` | ✅ |
| Built-in motion (`speed`, `direction`, `gravity`, `friction`) | ✅ |
| Sprites, `draw_*`, blending, alpha, `gpu_set_fog` flashes | ✅ |
| Text (`draw_text*`, `string_width/height`) | ✅ one built-in monospace font |
| Views and cameras (view 0, follow object, borders) | ✅ |
| Audio (`audio_play_sound`, gain, pitch, stop) | ✅ |
| Arrays (0-based), strings, maths, ds_list / ds_map / ds_grid, structs | ✅ |
| INI saving (`ini_*`) | ✅ |
| Collision masks | ⚠️ bounding boxes only (rotated masks become rotated AABBs) |
| mp3 sounds | ⚠️ convert them first with `tools/mp3towav.ps1` |
| Surfaces, `sprite_create_from_surface` | ❌ stubs; pre-render the art instead |
| Shaders, tile layers, paths, sequences, particles, gamepads | ❌ |

## Testing your port

`run.sh` takes an **autotest script**: a `;`-separated list of `tick:action` entries. The game runs
at 60 ticks per second at room speed 60.

```bash
./run.sh ../MyGameDefold 10 /tmp/shot \
  "30:kd=39;90:ku=39;100:kp=32;120:click=512,360;200:room=rmLevel2;220:eval=first(objPlayer).hp;400:quit"
```

| Action | Meaning |
|---|---|
| `kd=K` / `ku=K` / `kp=K` | Key down / up / press (GameMaker key code, for example `vk_right` = 39, `A` = 65) |
| `mm=X,Y` | Move the mouse (display pixels) |
| `md=1` / `mu=1` | Mouse button down / up |
| `click=X,Y` | Move the mouse there and left-click |
| `room=NAME` | Jump to a room |
| `eval=EXPR` | Print the value of a Lua expression |
| `quit` | Exit |

Errors inside events are caught and printed once with a traceback (`ERROR in objX: ...`), and the
game keeps running, so check the log after every run.

## Roadmap

The main goal is a **fully automatic GML → Lua transpiler**, so a GameMaker project converts into a
playable Defold project with no manual porting. The planned steps are:

- [ ] GML lexer and parser (GML 2.3+ syntax, structs, methods, constructors)
- [ ] Scope resolution (locals, instance variables, globals, assets, script functions)
- [ ] Lua code generation that applies the rules automatically (Lua 5.1 / HTML5 safe)
- [ ] Runtime coverage: surfaces through render targets, audio buffers, automatic mp3 conversion
- [ ] A conversion report and `--strict` mode
- [ ] An end-to-end test suite against a corpus of GameMaker project

## Contributing

- Run `./build.sh` on at least one converted project after you change the runtime or the converter.
- Keep the converter dependency-free (Python standard library only).
- Generated Lua must run on both LuaJIT and plain Lua 5.1 (no `goto`).
- Runtime additions belong in `template/gm/`, not in individual converted projects.
