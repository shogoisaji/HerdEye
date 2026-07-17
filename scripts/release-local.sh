#!/usr/bin/env bash
#
# Build, sign, notarize, staple, and package HerdEye locally.
#
# The Developer ID certificate is read from the local keychain. Notarization
# credentials are read from a notarytool keychain profile; no private key is
# written into the repository or passed through shell arguments.
#
# Usage:
#   scripts/release-local.sh 0.1.0
#   scripts/release-local.sh 0.1.0 --dmg
#   scripts/release-local.sh 0.1.0 --publish
#
# One-time setup:
#   xcrun notarytool store-credentials HerdEyeNotary \
#     --key /secure/path/AuthKey_<KEY_ID>.p8 \
#     --key-id <KEY_ID> \
#     --issuer <ISSUER_ID>
#
# Override the default notarytool profile with:
#   NOTARY_KEYCHAIN_PROFILE=MyProfile scripts/release-local.sh 0.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT_DIR/HerdEye.xcodeproj"
SCHEME="HerdEye"
APP_NAME="HerdEye"
DIST_DIR="$ROOT_DIR/dist"
EXPORT_OPTIONS_SOURCE="$ROOT_DIR/Config/ExportOptions-DeveloperID.plist"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-HerdEyeNotary}"

VERSION=""
PUBLISH=0
INCLUDE_DMG=0

usage() {
    cat <<EOF
Usage: $(basename "$0") <version> [options]

Builds a local Developer ID-signed and notarized HerdEye ZIP.

Options:
  --publish  Create/push tag and upload the ZIP to a GitHub Release.
  --dmg      Also create a notarized DMG using scripts/package-dmg.sh.
  -h, --help Show this help.

Environment:
  NOTARY_KEYCHAIN_PROFILE  notarytool keychain profile (default: HerdEyeNotary)
  BUILD_NUMBER              CFBundleVersion override (default: 1)

The --publish option requires a clean Git worktree and an authenticated gh CLI.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

read_build_setting() {
    local key="$1"
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
            print value
            exit
        }
    ' <<< "$BUILD_SETTINGS"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --publish)
            PUBLISH=1
            ;;
        --dmg)
            INCLUDE_DMG=1
            ;;
        -* )
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$VERSION" ]] || die "Only one version may be specified."
            VERSION="$1"
            ;;
    esac
    shift
done

[[ -n "$VERSION" ]] || { usage >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
    || die "Version must look like 1.2.3 or 1.2.3-beta.1: $VERSION"

if [[ "$PUBLISH" -eq 1 ]]; then
    require_command git
    require_command gh
    [[ -z "$(git status --porcelain)" ]] \
        || die "--publish requires a clean Git worktree."
fi

require_command xcodegen
require_command swift
require_command xcodebuild
require_command security
require_command codesign
require_command xcrun
require_command spctl
require_command ditto
require_command shasum

[[ -f "$EXPORT_OPTIONS_SOURCE" ]] \
    || die "Export options not found: $EXPORT_OPTIONS_SOURCE"

echo "▸ Generating Xcode project..."
(cd "$ROOT_DIR" && xcodegen generate)

[[ -d "$PROJECT" ]] || die "Generated project not found: $PROJECT"

echo "▸ Reading effective release settings..."
BUILD_SETTINGS="$(
    xcodebuild \
        -project "$PROJECT" \
        -target "$APP_NAME" \
        -configuration Release \
        -showBuildSettings \
        2>/dev/null
)"
TEAM_ID="$(read_build_setting DEVELOPMENT_TEAM)"
BUNDLE_ID="$(read_build_setting PRODUCT_BUNDLE_IDENTIFIER)"

[[ -n "$TEAM_ID" && "$TEAM_ID" != "YOUR_TEAM_ID" ]] \
    || die "Set DEVELOPMENT_TEAM in Config/Local.xcconfig or Config/Shared.xcconfig."
[[ -n "$BUNDLE_ID" && "$BUNDLE_ID" != "com.example.HerdEye" && "$BUNDLE_ID" != "com.yourname.HerdEye" ]] \
    || die "Set a real PRODUCT_BUNDLE_IDENTIFIER in Config/Local.xcconfig or Config/Shared.xcconfig."

BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+)*$ ]] \
    || die "BUILD_NUMBER must contain only numbers and dots: $BUILD_NUMBER"

echo "  team:   $TEAM_ID"
echo "  bundle: $BUNDLE_ID"
echo "  version: $VERSION"

echo "▸ Checking local Developer ID certificate..."
security find-identity -v -p codesigning 2>/dev/null \
    | grep -Fq 'Developer ID Application:' \
    || die "Developer ID Application certificate is not available in the local keychain."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/herdeye-release.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="$TMP_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$TMP_DIR/export"
NOTARIZE_ZIP="$TMP_DIR/$APP_NAME-$VERSION-notarize.zip"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
ZIP_SHA_PATH="$ZIP_PATH.sha256"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$ZIP_SHA_PATH"

echo "▸ Running Swift tests..."
(cd "$ROOT_DIR" && swift test)

echo "▸ Creating archive..."
(cd "$ROOT_DIR" && xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES)

echo "▸ Exporting Developer ID-signed app..."
EXPORT_OPTIONS="$TMP_DIR/ExportOptions-DeveloperID.plist"
cp "$EXPORT_OPTIONS_SOURCE" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS"

(cd "$ROOT_DIR" && xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH")

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || die "Exported app not found: $APP_PATH"

echo "▸ Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "▸ Preparing notarization upload..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "▸ Submitting to Apple notary service (this can take several minutes)..."
xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait

echo "▸ Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "▸ Creating Homebrew ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_SHA_PATH")")

echo "▸ Verifying packaged app..."
ZIP_VERIFY_PATH="$TMP_DIR/zip-verify"
mkdir -p "$ZIP_VERIFY_PATH"
ditto -x -k --rsrc "$ZIP_PATH" "$ZIP_VERIFY_PATH"
codesign --verify --deep --strict --verbose=2 "$ZIP_VERIFY_PATH/$APP_NAME.app"
xcrun stapler validate "$ZIP_VERIFY_PATH/$APP_NAME.app"
spctl --assess --type execute --verbose=2 "$ZIP_VERIFY_PATH/$APP_NAME.app"

DMG_PATH=""
DMG_SHA_PATH=""
if [[ "$INCLUDE_DMG" -eq 1 ]]; then
    require_command create-dmg
    echo "▸ Creating optional DMG..."
    AC_API_KEY_PROFILE="$NOTARY_KEYCHAIN_PROFILE" \
        VERSION="$VERSION" \
        "$SCRIPT_DIR/package-dmg.sh" "$APP_PATH"
    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    DMG_SHA_PATH="$DMG_PATH.sha256"
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_SHA_PATH")")
fi

echo "✓ Local release artifacts created:"
echo "  $ZIP_PATH"
echo "  $ZIP_SHA_PATH"
[[ -n "$DMG_PATH" ]] && echo "  $DMG_PATH" && echo "  $DMG_SHA_PATH"

if [[ "$PUBLISH" -eq 1 ]]; then
    echo "▸ Preparing GitHub Release..."
    gh auth status >/dev/null 2>&1 || die "Authenticate gh first: gh auth login"

    TAG="v$VERSION"
    HEAD_COMMIT="$(git rev-parse HEAD)"
    if git show-ref --verify --quiet "refs/tags/$TAG"; then
        [[ "$(git rev-list -n 1 "$TAG")" == "$HEAD_COMMIT" ]] \
            || die "Tag $TAG already exists but does not point to HEAD."
    else
        git tag -a "$TAG" -m "Release $TAG" "$HEAD_COMMIT"
    fi
    git push origin "$TAG"

    RELEASE_ASSETS=("$ZIP_PATH" "$ZIP_SHA_PATH")
    [[ -n "$DMG_PATH" ]] && RELEASE_ASSETS+=("$DMG_PATH" "$DMG_SHA_PATH")

    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "${RELEASE_ASSETS[@]}" --clobber
    else
        gh release create "$TAG" "${RELEASE_ASSETS[@]}" \
            --verify-tag \
            --title "$APP_NAME $VERSION" \
            --generate-notes
    fi
    echo "✓ Published GitHub Release: $TAG"
fi
