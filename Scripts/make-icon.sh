#!/bin/bash
# Generate the app icon in both forms the two build systems need:
#
#   build/AppIcon.icns                     — for Scripts/app-bundle.sh (SwiftPM path)
#   Support/Assets.xcassets/AppIcon.*      — for Netlogs.xcodeproj (Xcode path)
#
# Both come from the same 1024px render, so the two build systems can't drift.
# The .icns lands in build/ (gitignored, regenerated on demand); the asset
# catalog is committed, because Xcode needs it present to open the project.
#
# Idempotent. app-bundle.sh skips it when build/AppIcon.icns already exists;
# run it directly after editing Scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

swiftc Scripts/make-icon.swift -o build/make-icon
./build/make-icon build/icon-1024.png

# --- .icns for the script path -----------------------------------------------
SET=build/AppIcon.iconset
rm -rf "$SET"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s      build/icon-1024.png --out "$SET/icon_${s}x${s}.png"      >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o build/AppIcon.icns
rm -rf "$SET" build/make-icon
echo "wrote build/AppIcon.icns"

# --- asset catalog for the Xcode path ----------------------------------------
# One PNG per pixel size; the Contents.json below maps each to its
# (size, scale) slot. 32 and 256 and 512 each serve two slots (e.g. 32px is
# both 32x32@1x and 16x16@2x), so the files are named by pixel size, not slot.
ICONSET=Support/Assets.xcassets/AppIcon.appiconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px build/icon-1024.png --out "$ICONSET/icon_${px}.png" >/dev/null
done

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",     "scale" : "1x", "filename" : "icon_16.png"   },
    { "idiom" : "mac", "size" : "16x16",     "scale" : "2x", "filename" : "icon_32.png"   },
    { "idiom" : "mac", "size" : "32x32",     "scale" : "1x", "filename" : "icon_32.png"   },
    { "idiom" : "mac", "size" : "32x32",     "scale" : "2x", "filename" : "icon_64.png"   },
    { "idiom" : "mac", "size" : "128x128",   "scale" : "1x", "filename" : "icon_128.png"  },
    { "idiom" : "mac", "size" : "128x128",   "scale" : "2x", "filename" : "icon_256.png"  },
    { "idiom" : "mac", "size" : "256x256",   "scale" : "1x", "filename" : "icon_256.png"  },
    { "idiom" : "mac", "size" : "256x256",   "scale" : "2x", "filename" : "icon_512.png"  },
    { "idiom" : "mac", "size" : "512x512",   "scale" : "1x", "filename" : "icon_512.png"  },
    { "idiom" : "mac", "size" : "512x512",   "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > Support/Assets.xcassets/Contents.json <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "wrote $ICONSET"
