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
EXPORT_PLIST="$ROOT/scripts/ExportOptions-testflight.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }

# App Store Connect authentication. Xcode's own account session expires and
# then the upload dies with "Your session has expired", so the ship uses an API
# key instead. The key and its identifiers live outside the repository: this
# script reads them from the environment, or from ~/.atlas-ship.env when it
# exists. Nothing about the account is committed here.
ATLAS_SHIP_ENV="${ATLAS_SHIP_ENV:-$HOME/.atlas-ship.env}"
if [[ -f "$ATLAS_SHIP_ENV" ]]; then
  # shellcheck disable=SC1090  # the file is the user's local config
  set -a; source "$ATLAS_SHIP_ENV"; set +a
fi
ASC_KEY_DIR="${ATLAS_ASC_KEY_DIR:-$HOME/ASC_KEY_DIR}"
ASC_KEY_ID="${ATLAS_ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ATLAS_ASC_ISSUER_ID:-}"
ASC_ARGS=()
asc_ready() { [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -f "$ASC_KEY_DIR/AuthKey_$ASC_KEY_ID.p8" ]]; }
if asc_ready; then
  ASC_ARGS=(-authenticationKeyPath "$ASC_KEY_DIR/AuthKey_$ASC_KEY_ID.p8"
            -authenticationKeyID "$ASC_KEY_ID"
            -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

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
  # The end-to-end flows (just ui-test-ios, just e2e) need a booted simulator
  # and the live TfL feed, so they are a manual step before a ship, not part
  # of it.
  (cd "$ROOT" && just check)
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
    "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" \
    CURRENT_PROJECT_VERSION="$SHIP_BUILD" archive >"$OUT/archive.log" 2>&1 \
    || { tail -25 "$OUT/archive.log" >&2; fail "Archive failed. Full log: $OUT/archive.log"; }
  [[ -d "$ARCHIVE/Products/Applications" ]] || fail 'The archive has no Applications folder.'
  # The product is named after the target ("Atlas iOS.app"); find it rather
  # than assume a name.
  APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "$APP" ]] || fail 'The archive has no app in it.'
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
  # No development signing may reach TestFlight. The signature is read into a
  # variable first: `codesign | grep -q` would trip over pipefail, because grep
  # exits the moment it matches and codesign dies of SIGPIPE.
  local authority
  authority="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
  if grep -qE 'Authority=Apple Development' <<<"$authority"; then
    fail 'The archive is signed with a development identity. App Store Connect needs an Apple Distribution certificate: create one in Xcode (Settings > Accounts > Manage Certificates) and archive again.'
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
  asc_ready || fail "No App Store Connect key configured. Set ATLAS_ASC_KEY_ID and ATLAS_ASC_ISSUER_ID and put AuthKey_<id>.p8 in $ASC_KEY_DIR, or list the three in $ATLAS_SHIP_ENV."
  # Export with the upload destination, which sends the build to App Store
  # Connect. The API key authenticates the upload, so the pipeline does not
  # depend on a live Xcode account session.
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$EXPORT_PLIST" "${ASC_ARGS[@]+"${ASC_ARGS[@]}"}" \
    -allowProvisioningUpdates >"$OUT/export.log" 2>&1 \
    || { tail -25 "$OUT/export.log" >&2; fail "Upload failed. Full log: $OUT/export.log"; }
}

ship_ios "${args[@]}"
