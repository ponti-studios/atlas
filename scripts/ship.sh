#!/usr/bin/env bash
# shellcheck disable=SC2034  # SHIP_* are read by the sourced ship-ios.sh
# Ship Atlas (iPhone + iPad) to TestFlight, the studio's way (ship-ios skill).
# Usage: scripts/ship.sh [--skip-checks] [--no-upload] [--allow-branch]
#   --no-upload   archive, audit and upload symbols, but do not send the build to App Store Connect
#   --allow-branch  build from a branch that is not origin/main (trials and hotfixes only)
# The Mac app ships through its own path (macos-app-distribution); this one is the iOS app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT/.agents/skills"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skills-dir) SKILLS_DIR="$2"; shift 2;;
    --skills-dir=*) SKILLS_DIR="${1#*=}"; shift;;
    *) args+=("$1"); shift;;
  esac
done
# shellcheck disable=SC1091  # resolved via --skills-dir at runtime
source "$SKILLS_DIR/ship-ios/scripts/lib.sh"
# shellcheck disable=SC1091  # resolved via --skills-dir at runtime
source "$SKILLS_DIR/ship-ios/scripts/ship-ios.sh"

SHIP_NAME=Atlas
SHIP_ROOT="$ROOT"
PROJECT="$ROOT/Atlas.xcodeproj"
SCHEME="Atlas iOS"
BUNDLE_ID="io.ponti.atlas.ios"
TEAM_ID="3QHJ2KN8AL"
OUT="$ROOT/.build/testflight"
ARCHIVE="$OUT/Atlas.xcarchive"
APP="$ARCHIVE/Products/Applications/Atlas.app"
EXPORT_PLIST="$ROOT/scripts/ExportOptions-testflight.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }

# The Xcode project is generated from project.yml, so a fresh checkout has to
# make it before it can build.
ensure_project() {
  [[ -d "$PROJECT" ]] && return 0
  command -v xcodegen >/dev/null || fail 'xcodegen is missing; install it (brew install xcodegen) or run "just gen" on a checkout that has the project.'
  note 'Generating the Xcode project from project.yml'
  (cd "$ROOT" && xcodegen generate)
}

ship_check() {
  # The hermetic gate: the core package and both platforms build and test.
  (cd "$ROOT" && just check)
  (cd "$ROOT" && just test-ios)
}

ship_build() {
  command -v xcodebuild >/dev/null || fail 'xcodebuild is unavailable; install/select Xcode first.'
  ensure_project
  rm -rf "$OUT"
  mkdir -p "$OUT"

  # A timestamp keeps every upload's build number higher than the last one.
  SHIP_BUILD="$(date +%y%m%d%H%M)"
  note "Archiving build $SHIP_BUILD (Release)"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$SHIP_BUILD" archive >"$OUT/archive.log" 2>&1 \
    || { tail -25 "$OUT/archive.log" >&2; fail "Archive failed. Full log: $OUT/archive.log"; }
  [[ -d "$APP" ]] || fail 'The archive has no Atlas.app.'
  SHIP_VERSION="$(plist "$APP" CFBundleShortVersionString)"
  SHIP_ARTIFACT="$ARCHIVE"
}

ship_audit() {
  # The release identity: right bundle, right build number, no encryption claim.
  local bundle
  bundle="$(plist "$APP" CFBundleIdentifier)"
  [[ "$bundle" == "$BUNDLE_ID" ]] || fail "The archive is $bundle; the release bundle is $BUNDLE_ID."
  [[ "$(plist "$APP" CFBundleVersion)" == "$SHIP_BUILD" ]] \
    || fail 'The archived build number is not the one this ship stamped.'
  [[ "$(plist "$APP" ITSAppUsesNonExemptEncryption)" == false ]] \
    || fail 'ITSAppUsesNonExemptEncryption is not set to NO.'
  # No development signing may reach TestFlight.
  if codesign -dv --verbose=2 "$APP" 2>&1 | grep -qE 'Authority=Apple Development'; then
    fail 'The archive is signed with a development identity.'
  fi
  # Nothing shaped like a key may be in the build. Atlas carries no provider
  # keys today; the check stays so a future one cannot slip in.
  if LC_ALL=C grep -rqaE '(sk-or-v1-[0-9a-f]{16,}|sk-[A-Za-z0-9]{32,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$APP"; then
    fail 'Something shaped like a secret key is in the build.'
  fi
  ok "$SHIP_NAME $SHIP_VERSION ($SHIP_BUILD), bundle $bundle, no key in the build"
}

ship_symbols() {
  # Atlas has no crash reporter yet, so there is nowhere to send dSYMs; they
  # ride along with the archive upload (uploadSymbols in the export options),
  # which is what Apple's own symbolication reads.
  warn 'Atlas has no crash reporter configured; dSYMs travel with the build for App Store Connect.'
}

ship_upload() {
  # Export with the upload destination, which sends the build to App Store Connect
  # (Xcode must be signed in, or an App Store Connect API key must be set).
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$EXPORT_PLIST" -allowProvisioningUpdates >"$OUT/export.log" 2>&1 \
    || { tail -25 "$OUT/export.log" >&2; fail "Upload failed. Full log: $OUT/export.log"; }
}

ship_ios "${args[@]}"
