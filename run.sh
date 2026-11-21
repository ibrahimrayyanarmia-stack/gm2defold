#!/bin/bash
# Run a built Defold project with the Windows engine, print its log and take screenshots.
# usage: ./run.sh <project dir> [seconds=6] [screenshot prefix] [autotest script]
#   SHOT_TIMES="2 5" (seconds from start, default: just before the end)
#   autotest script example: "60:kd=39;120:ku=39;150:click=400,300;200:eval=first(objPlayer).x"
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$1" && pwd)"; SECS=${2:-6}; SHOT=$3; AT=$4
cd "$P"
NAME="dm_$(basename "$P" | tr -cd '[:alnum:]')"
cp -u "$HERE/engine/dmengine.exe" "$P/build/$NAME.exe"
for d in "$HERE"/engine/*.dll; do cp -u "$d" "$P/build/"; done
ARGS=()
[ -n "$AT" ] && ARGS+=("--config=gm.autotest=$AT")
"$P/build/$NAME.exe" "${ARGS[@]}" build/default/game.projectc > "$P/build/run.log" 2>&1 &
PID=$!
T=0
TIMES=${SHOT_TIMES:-$((SECS-1))}
for st in $TIMES; do
  sleep $((st - T)); T=$st
  if [ -n "$SHOT" ]; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$HERE/engine/shot.ps1")" "$(wslpath -w "${SHOT}_${st}s.png")" "$NAME"
    echo "screenshot: ${SHOT}_${st}s.png"
  fi
done
[ $SECS -gt $T ] && sleep $((SECS - T))
taskkill.exe /F /IM "$NAME.exe" >/dev/null 2>&1; kill $PID 2>/dev/null
grep -v "^INFO:ENGINE: \(Defold\|Engine service\|Loading data\|Initialised sound\|Target listening\|Version\|Current\|Renderer\|Vendor\)\|INFO:DLIB\|INFO:GRAPHICS\|INFO:CRASH\|INFO:PROFILER\|INFO:SOUND\|Unable to convert 'true'" "$P/build/run.log" | head -${LOG_LINES:-80}
