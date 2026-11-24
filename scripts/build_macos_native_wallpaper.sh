#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$project_root/build/native-wallpaper"
mkdir -p "$output"
xcrun swiftc -O -target "$(uname -m)-apple-macos14.0" \
  "$project_root/wallpaper/macos/WallpaperFrameClock.swift" \
  "$project_root/wallpaper/macos/VideoClip.swift" \
  "$project_root/wallpaper/macos/WallpaperView.swift" \
  "$project_root/wallpaper/macos/WallpaperMain.swift" \
  -o "$output/AmadeusWallpaper"
printf '%s\n' "$output/AmadeusWallpaper"
