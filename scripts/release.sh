#!/bin/bash
# One-shot Onglai release: bump version -> build -> zip -> tag -> GitHub Release.
#
#   usage: scripts/release.sh <version> [notes.md]
#
# Build number auto-increments. The tag is the bare version (no "v" prefix):
# the in-app updater compares tag against CFBundleShortVersionString as
# STRINGS, so keep versions lexicographically ordered (after 5.9 go to 6.0,
# not 5.10, or the updater will think 5.10 is older).
set -euo pipefail

VERSION="${1:?usage: release.sh <version> [notes.md]}"
NOTES="${2:-}"
cd "$(git rev-parse --show-toplevel)"

[ -z "$(git status --porcelain)" ] || { echo "error: working tree not clean"; exit 1; }

CURRENT_BUILD=$(grep -m1 'APP_BUILD = [0-9]' Pearcleaner.xcodeproj/project.pbxproj | grep -o '[0-9]\+')
BUILD=$((CURRENT_BUILD + 1))
echo "Releasing ${VERSION} (build ${BUILD})"

/usr/bin/sed -i '' "s/APP_VERSION = [0-9.]*;/APP_VERSION = ${VERSION};/g" Pearcleaner.xcodeproj/project.pbxproj
/usr/bin/sed -i '' "s/APP_BUILD = [0-9][0-9]*;/APP_BUILD = ${BUILD};/g" Pearcleaner.xcodeproj/project.pbxproj

DERIVED="$(mktemp -d)/DerivedData"
xcodebuild -project Pearcleaner.xcodeproj -scheme "Pearcleaner Release" -configuration Release \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM=VNGFZ627N6 CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  PROVISIONING_PROFILE_SPECIFIER= -allowProvisioningUpdates build 2>&1 | grep -E "\*\* BUILD" || {
    echo "error: build failed"; git checkout -- Pearcleaner.xcodeproj/project.pbxproj; exit 1; }

APP="$DERIVED/Build/Products/Release/Onglai.app"
ZIP="/tmp/Onglai-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Packaged $(du -h "$ZIP" | cut -f1) at $ZIP"

git commit -qam "chore: release ${VERSION} (build ${BUILD})"
git tag "${VERSION}"
git push -q origin main "refs/tags/${VERSION}"

# -R pins the target repo: with an "upstream" remote configured, gh would
# otherwise resolve the base repo to alienator88/Pearcleaner
if [ -n "$NOTES" ]; then
  gh release create "${VERSION}" "$ZIP" -R ysya/Onglai --title "Onglai ${VERSION}" --notes-file "$NOTES"
else
  gh release create "${VERSION}" "$ZIP" -R ysya/Onglai --title "Onglai ${VERSION}" --generate-notes
fi
echo "Released: https://github.com/ysya/Onglai/releases/tag/${VERSION}"
