#!/usr/bin/env bash
#
# render-icons.sh — regenerate every raster icon from the branding SVGs.
#
# `Macget/Resources/Branding/macget-icon.svg` is the single source of truth for
# the app's visual identity. Before this script existed the PNGs were exported
# by hand, so nothing tied them to the SVG and the two could drift silently.
# Run this after any change to the branding SVGs.
#
# Requires librsvg (chosen over cairosvg because it renders the arrowhead's
# feGaussianBlur/feMerge drop shadow correctly):
#
#     brew install librsvg
#
# Usage:
#     ./scripts/render-icons.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

ICON="Macget/Resources/Branding/macget-icon.svg"
WORDMARK="Macget/Resources/Branding/macget-wordmark.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert not found. Install it with: brew install librsvg" >&2
    exit 1
fi

for f in "$ICON" "$WORDMARK"; do
    [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

# render <src-svg> <pixel-size> <dest-png>
render() {
    local src="$1" size="$2" dest="$3"
    mkdir -p "$(dirname "$dest")"
    rsvg-convert -w "$size" -h "$size" "$src" -o "$dest"
    echo "  ${size}x${size}  $dest"
}

echo "AppIcon.appiconset"
APPICON="Macget/Assets.xcassets/AppIcon.appiconset"
# @1x and @2x for each of the five macOS icon slots. The @2x file for slot N is
# the same pixel size as the @1x for slot N+1, but Xcode requires both files.
render "$ICON"   16 "$APPICON/icon_16x16.png"
render "$ICON"   32 "$APPICON/icon_16x16@2x.png"
render "$ICON"   32 "$APPICON/icon_32x32.png"
render "$ICON"   64 "$APPICON/icon_32x32@2x.png"
render "$ICON"  128 "$APPICON/icon_128x128.png"
render "$ICON"  256 "$APPICON/icon_128x128@2x.png"
render "$ICON"  256 "$APPICON/icon_256x256.png"
render "$ICON"  512 "$APPICON/icon_256x256@2x.png"
render "$ICON"  512 "$APPICON/icon_512x512.png"
render "$ICON" 1024 "$APPICON/icon_512x512@2x.png"

echo "BrowserExtension"
for browser in chromium firefox; do
    for size in 16 32 48 128; do
        render "$ICON" "$size" "BrowserExtension/$browser/icons/icon-$size.png"
    done
done

# launch/ is gitignored (social/marketing assets). Only refresh it if present.
if [ -d "launch/linkedin" ]; then
    echo "launch/linkedin"
    render "$ICON" 300 "launch/linkedin/macget-logo-300-square.png"
    # The non-square LinkedIn logos are the wordmark, not the icon.
    rsvg-convert -w 300 "$WORDMARK" -o "launch/linkedin/macget-logo-300.png"
    echo "  300w      launch/linkedin/macget-logo-300.png"
    rsvg-convert -w 400 "$WORDMARK" -o "launch/linkedin/macget-logo-400.png"
    echo "  400w      launch/linkedin/macget-logo-400.png"
    # The .jpg needs a flattened white background — the SVG is transparent.
    if command -v sips >/dev/null 2>&1; then
        sips -s format jpeg "launch/linkedin/macget-logo-300.png" \
            --out "launch/linkedin/macget-logo-300.jpg" >/dev/null
        echo "  300w      launch/linkedin/macget-logo-300.jpg"
    fi
fi

echo
echo "Done. Check the 16px render — the arrowhead's drop shadow can smear at that size."
