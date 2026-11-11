# Atlas — Geolocation Multitool (Apple Multiplatform)

A native Apple multiplatform app (iPhone, iPad, Mac) built with 100% Apple tech
(Swift, SwiftUI, MapKit, CoreLocation) and the **Reflex** architecture: a
UI-free `AtlasCore` module, Elm-style ViewModels, an introspection contract,
a headless CLI, and behavior tests.

Apple Maps is the interface base layer. Everything else — walks, places,
flights, parcels, TFL — is drawn as an overlay above it, controlled from
state that lives entirely in `AtlasCore`.

## Features
- **Walks** — recorded routes, drawn as glowing polylines with start/finish pins.
- **Places** — saved coordinates pinned on the map; search Apple Maps for anything and save it.
- **Flights** — great-circle arcs between airports with bearing-aligned planes.
- **Parcels** — last-known positions with pulsing markers.
- **TFL** — London stations ringed in their line colours.
- **Cameras** — live TfL JamCams, drawn as a coverage layer with a live snapshot monitor. Tap a street-level dot and its monitor opens.
- **Sidebar** — search and scroll every item in the active section; collapsible on Mac, a slide-over drawer on iPhone.

## Design
"Midnight Cartographer": a full-bleed dark map, floating glass HUD, and lime
`#7CFFC4` / cyan `#5BD6FF` accents. Navigation is a ChatGPT-style left sidebar:
section switcher, live search, and a vertically scrolling list of every item in
the active section. On Mac it is a permanent 302 pt column that collapses to a
70 pt icon rail; on iPhone and iPad portrait it is a slide-over drawer. The hero
HUD and map controls float over the map, and the title bar is hidden so the map
runs edge to edge.

## Structure
- `AtlasCore/` — Swift Package: models, store, ViewModels, map state,
  introspection, tree, transport, CLI, tests.
- `Shared/` — SwiftUI views: `AtlasMap` (MapKit layer), `ContentView` (HUD),
  `Theme` (palette, glass, chrome).
- `iOS/`, `macOS/` — app entry points.
- `TestsUITests/` — XCUITest end-to-end flows (iOS and macOS targets).
- `maestro/` — Maestro touch flows for the simulator.
- `scripts/ship.sh` — the TestFlight adapter for the `ship-ios` skill.
- `.agents/skills/` — the studio skills, installed and pinned in `skills-lock.json`.
- `docs/design/` — verified screenshots of the running app.

## Build and test
```sh
just build-core     # swift build
just test-core      # 18 core tests
just build-ios
just build-mac      # Debug macOS
just run-mac        # Release macOS (use this for FPS work)
just ui-test-ios    # end-to-end: tap a camera dot, expect the monitor
just ui-test-mac    # the same, on the desktop
just maestro-ios    # the same, driven by touch through Maestro
just maestro-ios-place # search Apple Maps and save a place, by touch
just e2e            # both Maestro flows
just testflight     # ship the iOS app to TestFlight
just check          # everything above
```

`just testflight` runs the studio's `ship-ios` pipeline: it archives Release
from `project.yml`, audits the bundle, and uploads it to App Store Connect.
The full runbook is [`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md).


Run the macOS app from Xcode (scheme **Atlas macOS**) or open the built
product. The iOS scheme is **Atlas iOS**.

## Real data

The app runs on a portable snapshot built from real exports:

```sh
just import-data   # GPX directory + places CSV + flight legs -> atlas-data.json
just stats         # 92 walks / 12 months / 1,407 places / 38 flights
just push-ios-data # copy the snapshot into the booted simulator
just cams          # list the live TfL JamCam feed (network)
```

`atlas-data.json` lives in `~/Library/Application Support/Atlas` on macOS and in
the app's Documents directory on iOS. If it is missing, the app falls back to
the seeded demo data. `ATLAS_DATA_FILE` overrides both. Places you save in the
app are written to `atlas-places.json` beside it.

Import sources used here: 92 GPX tracks (87,682 points), 1,407 geocoded places
(151 rows skipped for missing coordinates, 143 duplicates collapsed), and 38
flight legs with airport coordinates. Parcels have no real feed, so the
tab renders an honest empty state.

## Live cameras

The **Cameras** tab reads TfL's live JamCam feed directly:

```
https://api.tfl.gov.uk/Place/Type/JamCam
```

It returns ~889 cameras with latitude/longitude, direction, availability and
S3 snapshot/video URLs. No key is required; set `TFL_APP_KEY` for a registered
key. The sidebar lists all 889 cameras, nearest first, and search filters the
whole network. Selecting one opens its live snapshot in the hero monitor,
refreshed every two minutes. Selection never moves the camera; the scope control
or the monitor's locate button zooms in on request. Locating a camera, or closing
its card, leaves you exactly where you were. TfL images keep their branding and
are never cropped. Run `just cams` to inspect the raw feed.

The layer is adaptive. From the network overview it is a count-weighted coverage
grid — a heat map of where cameras actually are. Once the map is closer than
~9 km of latitude span, it becomes the cameras themselves: individual dots,
culled to the viewport and capped at the nearest 200, so Bermondsey shows
Bermondsey's cameras instead of nothing. Both layers are drawn with projected
canvas fills (`MapReader` + `Canvas`) rather than `MapKit` overlays, so a zoom
never inserts or removes eighty renderers in a single frame. See
[`docs/perf/README.md`](docs/perf/README.md#live-cameras) for the before/after.

**Tap a dot, get the monitor.** At street level the dots are tappable: a tap
hit-tests the same projected points the canvas draws, so what you can see is
what you can click. The tap is a `SpatialTapGesture` on the map itself and runs
*alongside* MapKit's own pan and pinch, so dragging the map never fights the
selection. Selecting from the map still does not move the camera. Because
`synthesizing` a finger is impossible from a shell, the behaviour is covered by
UI tests on both platforms: they locate a camera through Reflex (which centres
it), clear the selection, tap the middle of the map and assert the monitor
reopens with the viewport untouched — `just ui-test-ios`, `just ui-test-mac`.
A [Maestro](https://maestro.mobile.dev) flow (`maestro/camera-tap.yaml`)
drives the same path by real touch on the simulator — drawer, search, locate,
close, tap the dot — and leaves the proof in
`docs/design/maestro-camera-tap.png`: `just maestro-ios`.

Loading real data surfaced and fixed four things: an async observation gap in
`AtlasTabs` (child view-model changes were not forwarded, so async loads never
redrew), a CRLF CSV parsing bug (Swift treats `\r\n` as one grapheme, so the
whole Transport file parsed as a single row), 38 overlapping flight labels, and
1,400 labelled pins turning a city into a cyan smear. Flights now label only the
focused/selected leg and order soonest-upcoming first; places render as density
dots until the camera is close; walk cards derive "Evening walk" from the GPX
activity and time.

## Finding places in Apple Maps

The **Places** section carries a second field, "Search Apple Maps", above the
list. It calls `MKLocalSearch` — Apple's own local search, no key, no account —
biased towards the middle of the map without being restricted to it, so
"Eiffel Tower" still finds Paris from California. Each result carries a save
control; saving adds the place to Atlas's places, pins it on the map, and
survives a relaunch.

Two rules keep the archive honest:

- **Identity is the place, not the row.** A result's id is a hash of its name
  and doorstep, so saving the same place twice updates it. A result that
  matches a place the archive already holds — same name, within 50 m — updates
  that place instead of adding a near-duplicate, because Apple and the CSV
  rarely agree on the last decimal of a coordinate.
- **User data lives beside the archive.** Saved places are written to
  `atlas-places.json` next to `atlas-data.json` (atomic write), and the
  imported snapshot is never mutated — it is machine-generated and rebuilt on
  every import. Deleting an imported place records a tombstone in the
  sidecar.

The seam is a protocol, not a service: `PlaceSearching` in `AtlasCore`, with
`MapKitPlaceSearch` as the implementation and a stub in the tests, so the
view model is proven without a network.


## Performance

The real archive (92 routes / 87,682 points / 1,407 places / 38 flights) drove a
measured optimisation pass. Baseline and final numbers, methodology, and raw
JSON live in [`docs/perf/`](docs/perf/README.md).

| metric | before | after |
|---|---:|---:|
| snapshot size | 7.6 MB | **1.2 MB** |
| snapshot decode (macOS Release) | 130.3 ms | **7.6 ms** |
| cold store + tabs load | 131.5 ms | **8.8 ms** |
| footprint after benchmark | 82 MB | **32 MB** |
| iOS session fps | 44.7 | **58.3–58.8** |
| iOS p95 frame | 41.1 ms | **16.7 ms** |
| iOS p99 frame | 82.5 ms | 28–33 ms |
| iOS worst frame | 758 ms | 92–107 ms |
| frames over budget | 16.0 % | **1.1–1.6 %** |

Headline changes: compact `Float32` route geometry in the snapshot, decode
started at app init, cards and render inputs cached outside `body`, Douglas–
Peucker overview LOD (87,682 → 4,514 vertices), places rendered as native
`MapCircle` vector overlays instead of 80–200 SwiftUI annotations, and a stable
overlay set so camera moves do not churn MapKit.

Camera page frame results: **107–114 fps at 120 Hz on macOS** and **55–60 fps
at 60 Hz on iOS**, with p95 at one frame and worst zoom frames down from 331 ms
to 33–34 ms. Zooming into the camera layer used to cost an 828 ms frame while
`MapKit` inserted the street-level dots; the canvas layer removed that spike
entirely. The detailed before/after is in
[`docs/perf/README.md`](docs/perf/README.md).

Measure it with:

```sh
just bench          # headless: decode, load, route LOD, place culling, cards
just bench-compare  # current run vs the recorded baseline
```

On macOS Release (native arm64) the same snapshot decodes in ~9 ms, tabs load in
under 1 ms, and launch-to-ready is ~0.45–0.63 s; idle CPU settles around 5 %.

On iOS, Release builds expose the Reflex server and frame probe when launched
with `ATLAS_REFLEX=1 ATLAS_PERF=1`; `perf frames start|stop` reports display-link
cadence. See [`docs/perf/README.md`](docs/perf/README.md) for the script and
caveats (simulator, 60 Hz cap, one-time renderer warm-up).

## Reflex control

State is introspectable and drivable, so the running app can be exercised
without touching the UI.

```sh
just ls             # active node: name, state, actions, map context
just tab 2          # switch feature (0 walks … 4 TFL)
just do MapToggle3D
just do MapCycleStyle
just map            # camera, style, pitch, actions
just repl           # interactive
```

In a Debug build both apps expose the same protocol on TCP `18765`
(`ls`, `do <Action> [json]`, `tab <N>`, `map`). Run one app at a time — the
port is exclusive; the second process logs a bind failure instead of
pretending to listen.

Sidebar and camera commands on the running app:

```sh
search kingston       # filter the active section; empty string clears
sidebar open|close    # the compact drawer
sidebar collapse|expand
camera <id|name>      # select; "first", "clear", "locate"
camera dots           # the street-level dots for the current viewport
camera status         # the selected camera, if any
places search <query> # search Apple Maps; results come back as JSON
places save <index>   # save the Nth result into the places list
places list [query]   # the saved places
perf frames start|stop
```

### Map actions
`MapZoomIn`, `MapZoomOut`, `MapCycleStyle`, `MapToggle3D`, `MapReset`.

Every active tab node also carries the current map camera as `context`, so an
agent can read the viewport from any feature.

## Screenshots
- `docs/design/macos-sidebar-walks.png`, `macos-sidebar-cameras.png`,
  `macos-sidebar-search.png` — desktop sidebar, real archive
- `docs/design/ios-sidebar-map.png`, `ios-sidebar-drawer.png` — iPhone map and drawer
- `docs/design/macos-walks.png`, `macos-places.png`, `macos-flights.png`,
  `macos-tfl.png`, `macos-3d.png` — desktop sections, real archive
- `docs/design/macos-cameras.png`, `macos-camera-live.png` — desktop, live TfL camera
- `docs/design/ios-walks.png`, `real-places.png`, `real-flights.png`,
  `ios-tfl.png`, `real-3d.png` — iPhone sections, real archive
- `docs/design/real-cameras.png`, `real-camera-live.png` — iPhone, live TfL camera
- `docs/design/ios-camera-street.png` — iPhone, street-level cameras as individual dots
- `docs/design/maestro-camera-tap.png` — iPhone, the monitor reopened by tapping a dot
- `docs/design/maestro-place-search.png` — iPhone, a place searched in Apple Maps and saved
- `docs/design/maestro-place-results.png` — iPhone, Apple's search results with the save control
- `docs/design/map-base.png`, `places.png`, `flights.png`, `tfl.png`,
  `walks-3d.png` — earlier bottom-dock layout (historical)
