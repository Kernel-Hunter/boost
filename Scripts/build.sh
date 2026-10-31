#!/bin/bash
# Builds Boost.app and installs it to /Applications as the single copy.
# Usage: Scripts/build.sh [--no-install]
#
# Builds through SwiftPM and wraps the resulting executable in a bundle, so
# there is one build path rather than two that can drift. Command Line Tools
# alone are enough; Xcode is not required.
set -euo pipefail
cd "$(dirname "$0")/.."

# One place. The release workflow reads it from here rather than being told
# separately, so a tag and a bundle cannot disagree about what they are.
VERSION="1.4.1"

# Where the app looks for new versions, and the key every update must be
# signed with. The feed is docs/appcast.xml, served by the project's GitHub
# Pages site; Scripts/appcast.sh adds each release to it. The public key's
# private half never leaves the maintainer's Keychain. See docs/releasing.md.
FEED_URL="https://kernel-hunter.github.io/boost/appcast.xml"
ED_PUBLIC_KEY="QKKfpvfADDZDhLbEDTOZ4QKgc5EgHgxP3hGulato8T8="

DEST="/Applications/Boost.app"
BUILD="build.noindex"
STAGE="$BUILD/Boost.app"
INSTALL=1
[ "${1:-}" = "--version" ] && { echo "$VERSION"; exit 0; }
[ "${1:-}" = "--no-install" ] && INSTALL=0

echo "compiling…"
mkdir -p "$BUILD"

# Built for both CPUs Macs actually ship on: Apple Silicon (arm64) and Intel
# (x86_64). Every current Mac, and the CI runner this also builds on, is
# arm64 — so building for the host alone produces an arm64-only binary. That
# doesn't run slower on an Intel Mac, it doesn't run at all: Rosetta
# translates x86_64 to arm64, never the other way.
#
# One invocation with two --arch flags, which SwiftPM merges into a single
# fat binary itself. An earlier version of this script ran two separate
# single-arch builds and merged them with lipo by hand, on the theory that
# passing --arch twice forces Xcode's XCBuild underneath. On the Swift 6.4
# toolchain shipping with current Command Line Tools that theory is simply
# wrong — swiftbuild is the default build system either way, no Xcode is
# involved, and it works with Command Line Tools alone. It's also the only
# option that still works there: that toolchain's --show-bin-path resolves
# to the same shared output directory regardless of --arch, so two separate
# single-arch builds silently overwrote each other before lipo ever ran.
swift build -c release --product boost --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --product boost --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_PATH/boost" "$BUILD/Boost"

# A universal build that silently narrowed to one slice would fail on
# exactly the machine this is meant to cover, and do it quietly. Checked
# once here rather than trusted.
SLICES="$(lipo -archs "$BUILD/Boost")"
for arch in arm64 x86_64; do
  case " $SLICES " in
    *" $arch "*) ;;
    *) echo "error: built binary is missing $arch (has: $SLICES)" >&2; exit 1 ;;
  esac
done
echo "  universal binary: $SLICES"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$BUILD/Boost" "$STAGE/Contents/MacOS/Boost"

# Sparkle, for in-app updates. SwiftPM leaves the framework next to the
# binary; the binary looks for it in Contents/Frameworks (the rpath is set in
# Package.swift). ditto rather than cp -R, because a framework is mostly
# symlinks and cp can flatten them into copies, which breaks its signature.
if [ ! -d "$BIN_PATH/Sparkle.framework" ]; then
  echo "error: Sparkle.framework not found in $BIN_PATH" >&2; exit 1
fi
ditto "$BIN_PATH/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Boost</string>
  <key>CFBundleDisplayName</key><string>Boost</string>
  <key>CFBundleExecutable</key><string>Boost</string>
  <key>CFBundleIdentifier</key><string>boost.local.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$ED_PUBLIC_KEY</string>
  <key>SUAllowsAutomaticUpdates</key><false/>
</dict></plist>
PLIST

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"

# Signed with a stable local identity, not ad-hoc ("-"). Ad-hoc signing keys
# TCC (Accessibility, etc.) to the exact compiled bytes, so every rebuild
# orphaned the grant and silently broke auto-quit-on-close. This identity
# stays the same across rebuilds, so the grant survives them.
# One-time setup that created it: see ../docs/codesigning.md
#
# CI has no such identity, so release builds are ad-hoc. Sparkle accepts an
# update between two ad-hoc builds: what it trusts is the EdDSA signature on
# the zip, and it only asks that the new app's own code signature be valid,
# not that it match the old one. See docs/releasing.md.
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Boost Local Dev"; then
  IDENTITY="Boost Local Dev"
else
  echo "  WARNING: 'Boost Local Dev' signing identity not found, falling back to ad-hoc."
  echo "  Accessibility permission will need re-granting after this build."
  IDENTITY="-"
fi

# Inside out, never --deep. --deep signs nested code in whatever order it
# finds it and gives every piece the same options, and Apple has deprecated
# it for signing. Sparkle's helpers are signed first, then the framework that
# contains them, then the app that contains the framework: each signature
# covers the ones inside it, so signing in any other order leaves a seal over
# code that was changed afterwards.
SPARKLE="$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --sign "$IDENTITY" "$@"; }
sign "$SPARKLE/XPCServices/Installer.xpc"
# The downloader service carries entitlements of its own (network client).
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$STAGE/Contents/Frameworks/Sparkle.framework"
sign "$STAGE"
codesign --verify --deep --strict "$STAGE"
echo "  signed: $IDENTITY"

if [ "$INSTALL" = 0 ]; then echo "built (not installed): $STAGE"; exit 0; fi

pkill -x Boost 2>/dev/null || true
sleep 1

# Exactly one Boost.app should exist. Clear out any stray copies first.
for stray in "$HOME/Applications/Boost.app" "$PWD/Boost.app"; do
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
