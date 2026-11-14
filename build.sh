#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
app="$PWD/dist/Dyland.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp dyland-sound.mp3 "$app/Contents/Resources/dyland-sound.mp3"
cp Resources/Dyland.icns "$app/Contents/Resources/Dyland.icns"
cp Resources/Hoodie-Cutout.png Resources/Hoodie-Blink.png "$app/Contents/Resources/"
cp .build/release/Dyland "$app/Contents/MacOS/Dyland"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
"$app/Contents/MacOS/Dyland" --self-check
print -r -- "Built $app"
