#!/bin/bash
# Builds Boost.app and installs it to /Applications as the single copy.
# Usage: ./build.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")"

DEST="/Applications/Boost.app"
BUILD="build.noindex"
STAGE="$BUILD/Boost.app"
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

echo "compiling…"
mkdir -p "$BUILD"
swiftc -O -parse-as-library -swift-version 5 \
       -o "$BUILD/Boost" \
       Sources/*.swift

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/Boost" "$STAGE/Contents/MacOS/Boost"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Boost</string>
  <key>CFBundleDisplayName</key><string>Boost</string>
  <key>CFBundleExecutable</key><string>Boost</string>
  <key>CFBundleIdentifier</key><string>boost.local.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict></plist>
PLIST

[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"

# Signed with a stable local identity, not ad-hoc ("-"). Ad-hoc signing keys
# TCC (Accessibility, etc.) to the exact compiled bytes, so every rebuild
# orphaned the grant and silently broke auto-quit-on-close. This identity
# stays the same across rebuilds, so the grant survives them.
# One-time setup that created it: see ../docs/codesigning.md
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Boost Local Dev"; then
  codesign --force --deep --sign "Boost Local Dev" "$STAGE" 2>&1 | grep -v "^$" || true
else
  echo "  WARNING: 'Boost Local Dev' signing identity not found — falling back to ad-hoc."
  echo "  Accessibility permission will need re-granting after this build."
  codesign --force --sign - "$STAGE" 2>/dev/null || echo "  (unsigned — still runs)"
fi

if [ "$INSTALL" = 0 ]; then echo "built (not installed): $STAGE"; exit 0; fi

pkill -x Boost 2>/dev/null || true
sleep 1

# Exactly one Boost.app should exist. Clear out any stray copies first.
for stray in "$HOME/Applications/Boost.app" "$(dirname "$PWD")/Boost.app"; do
  [ -e "$stray" ] && { echo "removing duplicate: $stray"; rm -rf "$stray"; }
done

rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" 2>/dev/null || true

rm -rf "$STAGE"          # leave no second bundle behind
sleep 1
COPIES=$(mdfind -name "Boost.app" 2>/dev/null | grep -c "Boost.app$" || true)
echo "installed: $DEST"
echo "Boost.app copies indexed on disk: ${COPIES:-?}"
