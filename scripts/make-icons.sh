#!/usr/bin/env bash
# Build the Atlas app icons from one 1024px source.
#
#   scripts/make-icons.sh <source.png>
#
# The source is a square, fully opaque 1024x1024 render (the one in
# docs/design/atlas-icon-1024.png). The script flattens any alpha onto the
# Atlas midnight, writes the iOS single-size icon and the whole macOS set,
# and keeps the marketing-sized PNG for App Store Connect.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT/docs/design/atlas-icon-1024.png}"
MIDNIGHT="#0A0F1E"

[[ -f "$SOURCE" ]] || fail "no source icon: $SOURCE"
command -v magick >/dev/null || fail 'ImageMagick is missing (brew install imagemagick).'

IOS_DIR="$ROOT/iOS/Assets.xcassets/AppIcon.appiconset"
MAC_DIR="$ROOT/macOS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$IOS_DIR" "$MAC_DIR" "$ROOT/docs/design"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Flatten onto the brand midnight and square the canvas up.
magick "$SOURCE" -background "$MIDNIGHT" -flatten -alpha off -resize 1024x1024 \
  -gravity center -extent 1024x1024 -strip "$work/base.png"

cp "$work/base.png" "$ROOT/docs/design/atlas-icon-1024.png"

# iOS: one universal 1024 icon; the system applies the mask.
cp "$work/base.png" "$IOS_DIR/icon-1024.png"

# macOS: every size Xcode asks for.
for size in 16 32 64 128 256 512 1024; do
  magick "$work/base.png" -resize "${size}x${size}" -strip "$MAC_DIR/icon-${size}.png"
done

cat >"$IOS_DIR/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

cat >"$MAC_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon-64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon-128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

# The asset catalogs themselves need a root Contents.json.
for catalog in "$ROOT/iOS/Assets.xcassets" "$ROOT/macOS/Assets.xcassets"; do
  cat >"$catalog/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
done

echo "icons written:"
echo "  iOS    $IOS_DIR"
echo "  macOS  $MAC_DIR"
echo "  marketing $ROOT/docs/design/atlas-icon-1024.png"
