#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_LIBS="/Applications/ShreffloPaint.app/Contents/lib"

echo "Compiling insert_stamp.m..."
clang -dynamiclib -arch arm64 -arch x86_64 \
  -framework Cocoa -framework AppKit \
  -I/Applications/ShreffloPaint.app/Contents/Resources/include/tuxpaint \
  -I/opt/homebrew/include/SDL2 \
  -I/opt/homebrew/include \
  -I"$DIR/include" \
  "$APP_LIBS/libSDL2-2.0.0.dylib" \
  "$APP_LIBS/libSDL2_image-2.0.0.dylib" \
  "$APP_LIBS/libSDL2_mixer-2.0.0.dylib" \
  "$APP_LIBS/libSDL2_gfx-1.0.0.dylib" \
  -o "$DIR/insert_stamp.dylib" \
  "$DIR/insert_stamp.m"

echo "Patching library install names for app bundle portability..."
for lib in libSDL2-2.0.0.dylib libSDL2_image-2.0.0.dylib libSDL2_mixer-2.0.0.dylib libSDL2_gfx-1.0.0.dylib; do
  install_name_tool -change "/opt/local/lib/$lib" "@executable_path/../lib/$lib" "$DIR/insert_stamp.dylib" 2>/dev/null || true
done

echo "Installing insert_stamp.dylib to ShreffloPaint apps..."
[ -d "/Applications/ShreffloPaint.app" ] && cp "$DIR/insert_stamp.dylib" /Applications/ShreffloPaint.app/Contents/Resources/lib/tuxpaint/plugins/insert_stamp.dylib 2>/dev/null || true
[ -d "$HOME/Desktop/ShreffloPaint.app" ] && cp "$DIR/insert_stamp.dylib" "$HOME/Desktop/ShreffloPaint.app/Contents/Resources/lib/tuxpaint/plugins/insert_stamp.dylib" 2>/dev/null || true

echo "Successfully built and installed ShreffloPaint PNG Stamp plugin!"
