#!/usr/bin/env bash
#
# Package a Developer ID-signed HerdEye.app into a notarized, stapled DMG.
#
# The .app must already be signed with a Developer ID Application certificate.
# Sign it in Xcode (Product → Archive → Distribute App → Copy App), which signs
# without notarizing. This script then packages, notarizes, and staples the DMG.
#
# Usage:
#   export AC_API_KEY_PROFILE=HerdEyeNotary
#   scripts/package-dmg.sh path/to/exported/HerdEye.app
#
# Prerequisites:
#   - create-dmg: `brew install create-dmg`
#   - Xcode Command Line Tools (codesign, spctl, xcrun, stapler)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_XCCONFIG="$ROOT_DIR/Config/Shared.xcconfig"
DIST_DIR="$ROOT_DIR/dist"

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <path/to/HerdEye.app>

Packages a Developer ID-signed HerdEye.app into a notarized, stapled DMG.

Notarization credentials:
  AC_API_KEY_PROFILE  notarytool keychain profile (recommended)

Legacy file-based credentials are also supported:
  AC_API_KEY_ID       App Store Connect API Key ID
  AC_API_KEY_ISSUER   App Store Connect Issuer ID
  AC_API_KEY_PATH     Path to the downloaded AuthKey_<KEYID>.p8

Prerequisites:
  create-dmg:        brew install create-dmg
  A Developer ID-signed .app exported from Xcode (signing only, not notarized)
EOF
    exit 1
}

die() { echo "error: $*" >&2; exit 1; }

# --- Resolve the .app path ---------------------------------------------------
APP="${1:-}"
[[ -n "$APP" ]] || usage
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[[ -d "$APP" ]] || die "App not found: $APP"
[[ "$(basename "$APP")" == *.app ]] || die "Expected a .app bundle: $APP"

# --- Required environment ----------------------------------------------------
if [[ -n "${AC_API_KEY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$AC_API_KEY_PROFILE")
else
    : "${AC_API_KEY_ID:?AC_API_KEY_ID or AC_API_KEY_PROFILE is required (see -h)}"
    : "${AC_API_KEY_ISSUER:?AC_API_KEY_ISSUER is required (see -h)}"
    : "${AC_API_KEY_PATH:?AC_API_KEY_PATH is required (see -h)}"
    [[ -f "$AC_API_KEY_PATH" ]] || die "API key file not found: $AC_API_KEY_PATH"
    NOTARY_ARGS=(
        --key "$AC_API_KEY_PATH"
        --key-id "$AC_API_KEY_ID"
        --issuer "$AC_API_KEY_ISSUER"
    )
fi

command -v create-dmg >/dev/null 2>&1 || die "create-dmg not found. Install it with: brew install create-dmg"

# --- Read version from xcconfig ----------------------------------------------
read_version() {
    [[ -f "$SHARED_XCCONFIG" ]] || die "Shared.xcconfig not found: $SHARED_XCCONFIG"
    local v
    v=$(grep -E '^MARKETING_VERSION' "$SHARED_XCCONFIG" | head -1 | cut -d= -f2 | tr -d ' ')
    [[ -n "$v" ]] || die "Could not read MARKETING_VERSION from $SHARED_XCCONFIG"
    echo "$v"
}
# Release workflows pass the tag-derived version explicitly. Local packaging
# continues to use MARKETING_VERSION from Shared.xcconfig by default.
VERSION="${VERSION:-$(read_version)}"

DMG="$DIST_DIR/HerdEye-${VERSION}.dmg"

echo "▸ Packaging HerdEye $VERSION"
echo "  app:  $APP"
echo "  dmg:  $DMG"

# --- Verify the app is Developer ID-signed -----------------------------------
echo "▸ Verifying signature..."
codesign --verify --deep --strict "$APP" \
    || die "codesign verification failed. Export a Developer ID-signed .app from Xcode."
spctl --assess -t execute "$APP" \
    || die "spctl assessment failed. The .app must be Developer ID-signed."

# --- Stage and build the DMG -------------------------------------------------
# create-dmg copies the staging directory's contents into the DMG root, so place
# the .app there and let --app-drop-link add the Applications shortcut.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"

mkdir -p "$DIST_DIR"
rm -f "$DMG"

echo "▸ Creating DMG with create-dmg..."
# create-dmg may return non-zero on cosmetic warnings; if the DMG exists, continue.
set +e
create-dmg \
    --volname "HerdEye" \
    --window-size 600 400 \
    --icon-size 100 \
    --app-drop-link 425 200 \
    "$DMG" \
    "$STAGING"
create_rc=$?
set -e
if [[ $create_rc -ne 0 ]]; then
    [[ -f "$DMG" ]] || die "create-dmg failed (exit $create_rc) and produced no DMG."
    echo "  (create-dmg reported warnings; DMG was produced, continuing.)"
fi

# --- Notarize via App Store Connect API Key ----------------------------------
echo "▸ Submitting to the notary service (this can take several minutes)..."
xcrun notarytool submit "$DMG" \
    "${NOTARY_ARGS[@]}" \
    --wait

# --- Staple and validate -----------------------------------------------------
echo "▸ Stapling the notarization ticket..."
xcrun stapler staple "$DMG"

echo "▸ Validating..."
xcrun stapler validate "$DMG"
spctl --assess -t open --context context:primary-signature "$DMG"

echo "✓ Done: $DMG"
