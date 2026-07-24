#!/bin/bash
#
# Builds a distributable Pomo.app and packages it as a .zip and a .dmg.
# Run from anywhere: ./publish/make-release.sh
#
# The app is signed ad-hoc on purpose. Signing with an "Apple Development"
# certificate would embed the developer's Apple ID email in the binary, and
# that certificate is not valid for distribution anyway. Ad-hoc keeps the
# artifacts free of personal identifiers; the cost is that macOS Gatekeeper
# requires a one-time bypass on first launch (see INSTALL.md).

set -euo pipefail

VERSION="${1:-1.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/publish"
STAGE="$(mktemp -d)"
DERIVED="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$DERIVED"' EXIT

echo "==> Building Pomo $VERSION (Release, ad-hoc signed)"
xcodebuild \
    -project "$ROOT/Pomo.xcodeproj" \
    -scheme Pomo \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build \
    > "$STAGE/build.log" 2>&1 \
    || { echo "Build failed. Last lines:"; tail -40 "$STAGE/build.log"; exit 1; }

APP="$DERIVED/Build/Products/Release/Pomo.app"
[ -d "$APP" ] || { echo "No Pomo.app produced"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP"

# The whole point of ad-hoc signing here is that nothing personal ships. Fail
# loudly rather than quietly publishing an identifier.
if codesign -dvvv "$APP" 2>&1 | grep -qiE "gmail|@|Apple Development"; then
    echo "Refusing to package: signature contains a developer identity."
    codesign -dvvv "$APP" 2>&1 | grep -iE "Authority|Identifier"
    exit 1
fi

# Ship no media. Videos are the user's own and live in Application Support.
if find "$APP" \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' \) | grep -q .; then
    echo "Refusing to package: video files found inside the bundle."
    exit 1
fi

echo "==> Packaging zip"
rm -f "$OUT/Pomo-$VERSION.zip"
# ditto rather than `zip`: preserves the code signature and resource forks.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Pomo-$VERSION.zip"

echo "==> Packaging dmg"
DMGSRC="$STAGE/dmg"
mkdir -p "$DMGSRC"
cp -R "$APP" "$DMGSRC/"
ln -s /Applications "$DMGSRC/Applications"
cp "$OUT/INSTALL.md" "$DMGSRC/INSTALL.md" 2>/dev/null || true
rm -f "$OUT/Pomo-$VERSION.dmg"
hdiutil create \
    -volname "Pomo $VERSION" \
    -srcfolder "$DMGSRC" \
    -ov -format UDZO \
    "$OUT/Pomo-$VERSION.dmg" \
    > /dev/null

echo "==> Checksums"
( cd "$OUT" && shasum -a 256 "Pomo-$VERSION.zip" "Pomo-$VERSION.dmg" > SHA256SUMS.txt )

echo
echo "Done:"
# du rather than parsing ls, whose columns break on paths containing spaces.
for f in "Pomo-$VERSION.zip" "Pomo-$VERSION.dmg"; do
    printf '  %-20s %s\n' "$f" "$(du -h "$OUT/$f" | cut -f1)"
done
cat "$OUT/SHA256SUMS.txt"
