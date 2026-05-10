#!/usr/bin/env bash
# Append a Sparkle appcast entry for the current release tag.
#
# Triggered after a GitHub release is published (not draft), since
# Sparkle's enclosure URL needs to resolve publicly. The script:
#
#   1. Downloads the release DMG from the published GitHub release.
#   2. Signs it with the EdDSA private key (Sparkle SUPublicEDKey pair).
#   3. Clones the gh-pages branch, appends a new <item> to appcast.xml,
#      and pushes.
#
# Required env vars:
#   TAG              the release tag (e.g. v0.5.0)
#   REPO             owner/name (e.g. sespiros/notchify)
#   SIGN_UPDATE      path to Sparkle's sign_update binary
#   ED_KEY_FILE      path to a file containing the base64 EdDSA priv key
#   GH_TOKEN         token with contents:write on REPO
#   RELEASE_BODY     plain-text release notes (may be empty)
set -euo pipefail

: "${TAG:?}" "${REPO:?}" "${SIGN_UPDATE:?}" "${ED_KEY_FILE:?}" "${GH_TOKEN:?}"
RELEASE_BODY="${RELEASE_BODY:-}"

VERSION="${TAG#v}"
DMG_NAME="Notchify-${VERSION}.dmg"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "downloading ${DMG_URL}"
curl -fsSL -o "${DMG_NAME}" "${DMG_URL}"

echo "signing ${DMG_NAME}"
# sign_update prints e.g. sparkle:edSignature="..." length="123456"
ATTRS=$("${SIGN_UPDATE}" --ed-key-file "${ED_KEY_FILE}" "${DMG_NAME}")
SIG=$(printf '%s' "$ATTRS" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LEN=$(printf '%s' "$ATTRS" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
if [ -z "$SIG" ] || [ -z "$LEN" ]; then
    echo "could not parse sign_update output: $ATTRS" >&2
    exit 1
fi

echo "cloning gh-pages"
git clone --depth 1 --branch gh-pages \
    "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" gh-pages
cd gh-pages
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Idempotency: if appcast already lists this version, do nothing. Lets
# the workflow be re-run safely (e.g. for an editorial change to the
# release body, where we'd just want to refresh the description).
if grep -q "<sparkle:version>${VERSION}</sparkle:version>" appcast.xml 2>/dev/null; then
    echo "appcast already contains ${VERSION}; nothing to do"
    exit 0
fi

PUBDATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# CDATA-safe: split any "]]>" sequences in release notes.
SAFE_BODY=$(printf '%s' "$RELEASE_BODY" | sed 's/]]>/]]]]><![CDATA[>/g')

NEW_ITEM=$(cat <<EOF
        <item>
            <title>${TAG}</title>
            <pubDate>${PUBDATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[${SAFE_BODY}]]></description>
            <enclosure url="${DMG_URL}" sparkle:edSignature="${SIG}" length="${LEN}" type="application/octet-stream"/>
        </item>
EOF
)

# Insert new item right before </channel>. awk handles the splice
# without dragging in xmlstarlet just for one tag.
awk -v item="$NEW_ITEM" '
    /<\/channel>/ { print item }
    { print }
' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml

git add appcast.xml
git commit -m "appcast: ${TAG}"
git push origin gh-pages
