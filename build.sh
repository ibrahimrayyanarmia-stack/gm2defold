#!/bin/bash
# Build a Defold project with the bob builder bundled in the local Defold editor (no editor needed).
# usage: ./build.sh <project dir> [extra bob args]      e.g. ./build.sh ../MyGame
P="$(cd "$1" && pwd)"; shift
J="/mnt/c/defold/packages/jdk-21.0.5+11/bin/java.exe"
JAR=$(wslpath -w /mnt/c/defold/packages/defold-5944eddf7392f6735768b5dfc495695b63ef3c76.jar)
"$J" -cp "$JAR" com.dynamo.bob.Bob --root "$(wslpath -w "$P")" "$@" build 2>&1 | grep -v "^Working\|Reading classes\|^ *[0-9]*% \|Cleaning engine\|Failed to clean up temp" 
