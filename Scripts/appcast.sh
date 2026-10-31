#!/bin/bash
# Adds a published release to the update feed, docs/appcast.xml.
# Usage: Scripts/appcast.sh <version>        e.g. Scripts/appcast.sh 1.5.0
#
# Run it after the release workflow has published v<version>. It downloads
# that release's Boost.zip, checks it against the SHA-256 the workflow wrote
# into the release notes, signs it with the EdDSA key in your login Keychain,
# and adds (or replaces) the matching item in the feed. Then it commits.
# Pushing that commit is what makes existing installs see the update.
#
# Signing happens here, on your Mac, and not in CI on purpose: the private key
# would otherwise have to be a GitHub secret, and anyone who got it could ship
# an update to every Boost user.
#
# Needs: curl, python3, and Sparkle's sign_update. `swift build` downloads it
# into .build/artifacts; set SPARKLE_BIN to use another copy. The first run
# makes macOS ask whether sign_update may use the key; choose Always Allow.
# If the Keychain is not an option, SPARKLE_KEY_FILE=<exported key file>
# signs with that instead (and skips the public key check below, which needs
# the Keychain).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Scripts/appcast.sh <version>   (for example 1.5.0)" >&2
  exit 1
fi

REPO="Kernel-Hunter/boost"
TAG="v$VERSION"
FEED="docs/appcast.xml"
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/Boost.zip"
NOTES_URL="https://github.com/$REPO/releases/tag/$TAG"

SPARKLE_BIN="${SPARKLE_BIN:-.build/artifacts/sparkle/Sparkle/bin}"
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "sign_update not found in $SPARKLE_BIN. Run 'swift build' once, or set SPARKLE_BIN." >&2
  exit 1
fi

# The feed edit goes into a commit, so start from a clean feed. A half-edited
# appcast.xml mixed into this commit is how a broken feed reaches users.
if ! git diff --quiet -- "$FEED" || ! git diff --cached --quiet -- "$FEED"; then
  echo "$FEED has uncommitted changes. Commit or discard them first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "reading release $TAG…"
curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$TAG" -o "$WORK/release.json" \
  || { echo "No published release $TAG on GitHub yet." >&2; exit 1; }

# The release notes carry a line "SHA-256: `<hash>`", written by release.yml
# from the zip it built. Checking against it means the file signed here is the
# one CI built, not whatever a redirect or a cache happened to hand back.
read -r EXPECTED PUBLISHED < <(python3 -I - "$WORK/release.json" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
match = re.search(r"SHA-256:\s*`([0-9a-f]{64})`", release.get("body") or "")
print(match.group(1) if match else "-", release.get("published_at") or "-")
PY
)
if [ "$EXPECTED" = "-" ]; then
  echo "The notes for $TAG have no SHA-256 line. Was it published by release.yml?" >&2
  exit 1
fi

echo "downloading Boost.zip…"
curl -fsSL "$ZIP_URL" -o "$WORK/Boost.zip"
ACTUAL="$(shasum -a 256 "$WORK/Boost.zip" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "Checksum mismatch for $ZIP_URL" >&2
  echo "  release notes: $EXPECTED" >&2
  echo "  downloaded:    $ACTUAL" >&2
  exit 1
fi
echo "  SHA-256 matches the release notes"

# Two mistakes that would only show up on users' Macs, caught here instead:
# a zip whose app is a different version than its tag, and an app that
# carries a different public key than the one we are about to sign with
# (every install of it would then refuse the next update).
ditto -x -k "$WORK/Boost.zip" "$WORK/unzipped"
PLIST="$WORK/unzipped/Boost.app/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "The app in the zip says $APP_VERSION, not $VERSION." >&2
  exit 1
fi
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
  echo "  signing with $SPARKLE_KEY_FILE; not checked against the app's key ($APP_KEY)"
else
  KEY_ARGS=()
  OUR_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
  if [ "$APP_KEY" != "$OUR_KEY" ]; then
    echo "The app's SUPublicEDKey ($APP_KEY) is not the key in your Keychain ($OUR_KEY)." >&2
    exit 1
  fi
fi

# Prints: sparkle:edSignature="…" length="…"
echo "signing…"
if ! SIGNED="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$WORK/Boost.zip" 2>&1)"; then
  echo "sign_update failed: $SIGNED" >&2
  exit 1
fi
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNED")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIGNED")"
if [ -z "$SIGNATURE" ] || [ -z "$LENGTH" ]; then
  echo "Could not read sign_update's output: $SIGNED" >&2
  exit 1
fi

python3 -I - "$FEED" "$VERSION" "$PUBLISHED" "$ZIP_URL" "$LENGTH" "$SIGNATURE" "$NOTES_URL" <<'PY'
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

feed, version, published, url, length, signature, notes = sys.argv[1:]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
s = lambda tag: f"{{{SPARKLE}}}{tag}"

tree = ET.parse(feed)
channel = tree.getroot().find("channel")

# Replacing rather than appending, so running this twice for one version
# (after a re-upload, say) leaves one item, not two that disagree.
for old in channel.findall("item"):
    if old.findtext(s("version")) == version:
        channel.remove(old)

when = datetime.now(timezone.utc) if published == "-" else \
    datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Boost {version}"
ET.SubElement(item, "pubDate").text = format_datetime(when)
ET.SubElement(item, s("version")).text = version
ET.SubElement(item, s("shortVersionString")).text = version
ET.SubElement(item, s("minimumSystemVersion")).text = "14.0"
# Shown inside the update window. Links in it open in the browser.
ET.SubElement(item, "description").text = (
    f'<p>See <a href="{notes}">what changed in Boost {version}</a> on GitHub.</p>')
# The "Version History" link Sparkle offers next to the notes.
ET.SubElement(item, s("fullReleaseNotesLink")).text = notes
ET.SubElement(item, "enclosure", {
    "url": url,
    "length": length,
    "type": "application/octet-stream",
    s("edSignature"): signature,
})

# Newest first, so the file reads like a changelog.
first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
channel.insert(first, item)

ET.indent(tree, space="  ")
tree.write(feed, encoding="utf-8", xml_declaration=True)
with open(feed, "a") as f:
    f.write("\n")
PY

if git diff --quiet -- "$FEED"; then
  echo "Boost $VERSION is already in $FEED exactly as signed now. Nothing to commit."
  exit 0
fi
git add "$FEED"
git commit -q -m "Add Boost $VERSION to the update feed" -- "$FEED"
echo "added Boost $VERSION to $FEED and committed it."
echo "Push it, and installed copies will offer the update on their next check."
