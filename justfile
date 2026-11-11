# Atlas dev workflow
set dotenv-load

# Package paths
core := "AtlasCore"
proj := "Atlas.xcodeproj"

# Build the headless core + CLI
build-core:
    cd {{core}} && swift build

# Run core tests (the Reflex behavior gate)
test-core:
    cd {{core}} && swift test

# Headless CLI: inspect state
ls:
    cd {{core}} && .build/debug/atlas-cli ls

# Headless CLI: run an action, e.g. just do Refresh
do ACTION:
    cd {{core}} && .build/debug/atlas-cli do '{{ACTION}}'

# Headless CLI: switch tabs, e.g. just tab 2
tab N:
    cd {{core}} && .build/debug/atlas-cli tab {{N}}

# Headless CLI: inspect the map camera, style, and actions
map:
    cd {{core}} && .build/debug/atlas-cli map

# Full CLI REPL
repl:
    cd {{core}} && .build/debug/atlas-cli

# List live TfL JamCams (network)
cams:
    cd {{core}} && .build/debug/atlas-cli cams --limit 20

# ---------------------------------------------------------------------------
# Real data
# ---------------------------------------------------------------------------

# Personal exports. Every path is overridable, so the repository carries no
# assumption about where your own data lives.
places_csv := env_var_or_default("ATLAS_PLACES_CSV", env_var_or_default("HOME", "") + "/Documents/data/places.csv")
gpx_dir := env_var_or_default("ATLAS_GPX_DIR", env_var_or_default("HOME", "") + "/Documents/data/gpx_routes")
travel := env_var_or_default("ATLAS_TRAVEL_DIR", env_var_or_default("HOME", "") + "/Documents/data/travel-export-package")
datafile := "Library/Application Support/Atlas/atlas-data.json"

# Import real GPX routes, places, and flights into the app snapshot
import-data:
    cd {{core}} && swift build
    cd {{core}} && .build/debug/atlas-cli import \
        --gpx "{{gpx_dir}}" \
        --places "{{places_csv}}" \
        --transport "{{travel}}/Transport.csv" \
        --airports "{{travel}}/Airports.csv" \
        --out "$HOME/{{datafile}}"

# Inspect the imported snapshot
stats:
    cd {{core}} && ATLAS_DATA_FILE="$HOME/{{datafile}}" .build/debug/atlas-cli stats

# ---------------------------------------------------------------------------
# Performance
# ---------------------------------------------------------------------------

# Headless benchmark: decode, load, route LOD, place culling, cards
bench:
    cd {{core}} && swift build -c release
    cd {{core}} && ATLAS_DATA_FILE="$HOME/{{datafile}}" .build/release/atlas-cli bench --iterations 5 --label current

# Compare the current run against the recorded baseline
bench-compare:
    cd {{core}} && swift build -c release
    cd {{core}} && ATLAS_DATA_FILE="$HOME/{{datafile}}" .build/release/atlas-cli bench --iterations 5 --label current --compare ../docs/perf/baseline-headless.json

# Re-record the baseline (do this before an optimisation pass)
bench-baseline:
    cd {{core}} && swift build -c release
    cd {{core}} && ATLAS_DATA_FILE="$HOME/{{datafile}}" .build/release/atlas-cli bench --iterations 5 --label baseline --out ../docs/perf/baseline-headless.json

# Copy the snapshot into the booted simulator's app container
push-ios-data:
    APP=$$(xcrun simctl get_app_container booted io.ponti.atlas.ios data); \
    cp "$HOME/{{datafile}}" "$$APP/Documents/atlas-data.json"; \
    echo "copied to $$APP/Documents/atlas-data.json"

# Regenerate Xcode project from project.yml
gen:
    xcodegen generate

# Build iOS
build-ios:
    xcodebuild -project {{proj}} -scheme 'Atlas iOS' -destination 'generic/platform=iOS' build

# Build macOS (Debug)
build-mac:
    xcodebuild -project {{proj}} -scheme 'Atlas macOS' -destination 'generic/platform=macOS' build

# Build and run the macOS Release app (the fast path; Debug is much slower)
run-mac:
    xcodebuild -project {{proj}} -scheme 'Atlas macOS' -configuration Release -destination 'generic/platform=macOS' build
    open "$$(find $$HOME/Library/Developer/Xcode/DerivedData/Atlas-*/Build/Products/Release -maxdepth 1 -name 'Atlas macOS.app' | head -1)"

# Run iOS unit tests
test-ios:
    xcodebuild -project {{proj}} -scheme 'Atlas iOS' -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AtlasTests test

# End-to-end: tap a camera dot, expect its monitor (needs the live TfL feed)
ui-test-ios:
    xcodebuild -project {{proj}} -scheme 'Atlas iOS' -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AtlasUITests test

# Maestro flow: drive the app by touch on the booted simulator
maestro-ios:
    JAVA_HOME="/opt/homebrew/opt/openjdk@17" \
        ~/.maestro/bin/maestro --device "$(xcrun simctl list devices booted | grep -m1 -E '^ *iPhone' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')" \
        test maestro/camera-tap.yaml
    cp "$(ls -t $HOME/.maestro/tests/*/camera-tap/takeScreenshot/docs/design/maestro-camera-tap.png | head -1)" docs/design/maestro-camera-tap.png

# Maestro flow: search Apple Maps for a place and save it
maestro-ios-place:
    -rm -f "$(xcrun simctl get_app_container booted io.ponti.atlas.ios data)/Documents/atlas-places.json"
    JAVA_HOME="/opt/homebrew/opt/openjdk@17" \
        ~/.maestro/bin/maestro --device "$(xcrun simctl list devices booted | grep -m1 -E '^ *iPhone' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')" \
        test maestro/place-search.yaml
    cp "$(ls -t $HOME/.maestro/tests/*/place-search/takeScreenshot/docs/design/maestro-place-search.png | head -1)" docs/design/maestro-place-search.png
    cp "$(ls -t $HOME/.maestro/tests/*/place-search/takeScreenshot/docs/design/maestro-place-results.png | head -1)" docs/design/maestro-place-results.png

# End-to-end on the desktop; the Reflex port is exclusive, so close the iOS app
ui-test-mac:
    -pkill -f "Atlas macOS"
    -xcrun simctl terminate booted io.ponti.atlas.ios
    xcodebuild -project {{proj}} -scheme 'Atlas macOS' -configuration Release -destination 'platform=macOS' -only-testing:AtlasMacUITests test

# ---------------------------------------------------------------------------
# Studio verbs (studio-dev): the same names in every studio repo
# ---------------------------------------------------------------------------

# Generate the Xcode project, build the core package. Safe to repeat.
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -d .agents/skills/ship-ios ]] || npx --yes skills experimental_install --yes
    xcodegen generate
    cd {{core}} && swift build

# Read-only checks: what is installed, what is missing, what is running.
doctor:
    @echo "Xcode:"; xcodebuild -version | head -1
    @echo "Swift:"; swift --version | head -1
    @echo "XcodeGen:"; xcodegen --version
    @echo "Booted simulator:"; xcrun simctl list devices booted | grep -m1 iPhone || echo "  none booted"
    @echo "Archive snapshot:"; ls -lh "$HOME/{{datafile}}" 2>/dev/null || echo "  missing - run: just import-data"
    @echo "Reflex port 18765:"; lsof -iTCP:18765 -sTCP:LISTEN -n -P 2>/dev/null | tail -1 || echo "  free"

# Build, install and launch on the booted simulator
sim:
    xcodebuild -project {{proj}} -scheme 'Atlas iOS' -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/dd-ios build
    -xcrun simctl terminate booted io.ponti.atlas.ios
    xcrun simctl install booted ".build/dd-ios/Build/Products/Release-iphonesimulator/Atlas iOS.app"
    APP=$$(xcrun simctl get_app_container booted io.ponti.atlas.ios data); cp "$HOME/{{datafile}}" "$$APP/Documents/atlas-data.json"
    SIMCTL_CHILD_ATLAS_REFLEX=1 xcrun simctl launch booted io.ponti.atlas.ios

# End-to-end flows on the simulator
e2e:
    just maestro-ios
    just maestro-ios-place

# Ship the iOS app to TestFlight, the studio way (ship-ios skill)
testflight *args:
    bash scripts/ship.sh {{args}}

# The installed skill set: version, refresh and drift check
studio-version:
    @cat .agents/skills/studio-dev/scripts/VERSION

studio-update:
    npx --yes skills experimental_install --yes

studio-check:
    @test -f skills-lock.json || (echo "skills-lock.json is missing" && exit 1)
    @test -d .agents/skills/ship-ios || (echo "the ship-ios skill is not installed" && exit 1)
    @test -d .agents/skills/studio-dev || (echo "the studio-dev skill is not installed" && exit 1)
    @echo "skills present: ship-ios, studio-dev"

# Run everything
check: build-core test-core build-ios build-mac
    @echo "all green"