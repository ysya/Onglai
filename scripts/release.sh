#!/bin/bash
# One-shot Onglai release: bump -> sign -> verify -> commit -> publish a draft
# release -> make it public.
#
# Free development-signed release (requires users to use Open Anyway):
#   ONGLAI_RELEASE_MODE=development \
#   ONGLAI_DEVELOPMENT_TEAM=ABCDE12345 \
#   scripts/release.sh <version> [notes.md]
#
# Notarized Developer ID release:
#   ONGLAI_DEVELOPMENT_TEAM=ABCDE12345 \
#   ONGLAI_NOTARY_PROFILE=onglai-notary \
#   scripts/release.sh <version> [notes.md]
#
# ONGLAI_NOTARY_PROFILE must name credentials previously stored with:
#   xcrun notarytool store-credentials <profile-name> ...
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [notes.md]}"
NOTES="${2:-}"
TEAM_ID="${ONGLAI_DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${ONGLAI_NOTARY_PROFILE:-}"
APP_GROUP_ID="${ONGLAI_APP_GROUP_IDENTIFIER:-${TEAM_ID}.group.onglai}"
RELEASE_MODE="${ONGLAI_RELEASE_MODE:-developer-id}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must use major.minor.patch format" >&2
  exit 1
fi

if [ "$RELEASE_MODE" != "developer-id" ] && [ "$RELEASE_MODE" != "development" ]; then
  echo "error: ONGLAI_RELEASE_MODE must be developer-id or development" >&2
  exit 1
fi

if [ -z "$TEAM_ID" ]; then
  echo "error: ONGLAI_DEVELOPMENT_TEAM is required" >&2
  exit 1
fi

if [ "$RELEASE_MODE" = "developer-id" ] && [ -z "$NOTARY_PROFILE" ]; then
  echo "error: ONGLAI_NOTARY_PROFILE is required for Developer ID releases" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

[ -z "$(git status --porcelain)" ] || { echo "error: working tree not clean" >&2; exit 1; }
[ -z "$(git tag --list "$VERSION")" ] || { echo "error: tag $VERSION already exists" >&2; exit 1; }

if [ "$RELEASE_MODE" = "development" ]; then
  IDENTITY_NAME="Apple Development:"
else
  IDENTITY_NAME="Developer ID Application:"
fi

if ! security find-identity -v -p codesigning | grep -F "$IDENTITY_NAME" >/dev/null; then
  echo "error: no ${IDENTITY_NAME%:} identity found" >&2
  exit 1
fi

CURRENT_BUILD=$(grep -m1 'APP_BUILD = [0-9]' Pearcleaner.xcodeproj/project.pbxproj | grep -o '[0-9]\+')
BUILD=$((CURRENT_BUILD + 1))
echo "Preparing Onglai ${VERSION} (build ${BUILD}, ${RELEASE_MODE})"

/usr/bin/sed -i '' "s/APP_VERSION = [0-9.]*;/APP_VERSION = ${VERSION};/g" Pearcleaner.xcodeproj/project.pbxproj
/usr/bin/sed -i '' "s/APP_BUILD = [0-9][0-9]*;/APP_BUILD = ${BUILD};/g" Pearcleaner.xcodeproj/project.pbxproj

WORK_DIR=$(mktemp -d /tmp/onglai-release.XXXXXX)
ARCHIVE="$WORK_DIR/Onglai.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
DERIVED_DATA="$WORK_DIR/DerivedData"
ZIP="$WORK_DIR/Onglai-${VERSION}.zip"
COMMITTED=0

cleanup() {
  if [ "$COMMITTED" -eq 0 ]; then
    git restore -- Pearcleaner.xcodeproj/project.pbxproj
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [ "$RELEASE_MODE" = "developer-id" ]; then
  cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
EOF

  xcodebuild \
    -project Pearcleaner.xcodeproj \
    -scheme "Pearcleaner Release" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ONGLAI_APP_GROUP_IDENTIFIER="$APP_GROUP_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    -quiet \
    archive

  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -quiet

  APP="$EXPORT_DIR/Onglai.app"
else
  echo "warning: creating a non-notarized Apple Development build"
  echo "warning: users must approve it with Privacy & Security > Open Anyway"

  xcodebuild \
    -project Pearcleaner.xcodeproj \
    -scheme "Pearcleaner Release" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ONGLAI_APP_GROUP_IDENTIFIER="$APP_GROUP_ID" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    PROVISIONING_PROFILE_SPECIFIER= \
    -allowProvisioningUpdates \
    -quiet \
    build

  APP="$DERIVED_DATA/Build/Products/Release/Onglai.app"
fi

[ -d "$APP" ] || { echo "error: exported Onglai.app not found" >&2; exit 1; }

ACTUAL_TEAM=$(codesign --display --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
ACTUAL_IDENTIFIER=$(codesign --display --verbose=4 "$APP" 2>&1 | awk -F= '/^Identifier=/{print $2}')
HELPER_TEAM=$(codesign --display --verbose=4 "$APP/Contents/MacOS/PearcleanerHelper" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')

[ "$ACTUAL_TEAM" = "$TEAM_ID" ] || { echo "error: app was signed by unexpected team $ACTUAL_TEAM" >&2; exit 1; }
[ "$HELPER_TEAM" = "$TEAM_ID" ] || { echo "error: helper was signed by unexpected team $HELPER_TEAM" >&2; exit 1; }
[ "$ACTUAL_IDENTIFIER" = "me.ysya.Onglai" ] || { echo "error: unexpected signing identifier $ACTUAL_IDENTIFIER" >&2; exit 1; }

if ! VERIFY_OUTPUT=$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1); then
  if [ "$RELEASE_MODE" != "development" ] || ! grep -F "CSSMERR_TP_NOT_TRUSTED" <<<"$VERIFY_OUTPUT" >/dev/null; then
    echo "$VERIFY_OUTPUT" >&2
    exit 1
  fi
  echo "warning: expected development-certificate trust failure: CSSMERR_TP_NOT_TRUSTED"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ "$RELEASE_MODE" = "developer-id" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP"

  # Repackage after stapling so the distributed app contains the ticket.
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

git add Pearcleaner.xcodeproj/project.pbxproj
git commit -m "chore: release ${VERSION} (build ${BUILD})"
COMMITTED=1
COMMIT_SHA=$(git rev-parse HEAD)
git push origin main

# Upload everything into a draft first. A failed upload never leaves users with
# a public tag that has no usable artifact.
if [ "$RELEASE_MODE" = "development" ]; then
  RELEASE_TITLE="Onglai ${VERSION} (development-signed)"
else
  RELEASE_TITLE="Onglai ${VERSION}"
fi

if [ -n "$NOTES" ]; then
  gh release create "$VERSION" "$ZIP" -R ysya/Onglai --target "$COMMIT_SHA" --draft --title "$RELEASE_TITLE" --notes-file "$NOTES"
else
  gh release create "$VERSION" "$ZIP" -R ysya/Onglai --target "$COMMIT_SHA" --draft --title "$RELEASE_TITLE" --generate-notes
fi
gh release edit "$VERSION" -R ysya/Onglai --draft=false
git fetch -q origin "refs/tags/${VERSION}:refs/tags/${VERSION}"

echo "Released: https://github.com/ysya/Onglai/releases/tag/${VERSION}"
