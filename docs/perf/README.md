# Atlas performance record

Everything here is measured, not estimated. The harness has three layers:

1. **Headless core benchmark** — `atlas-cli bench` runs each real stage
   independently against `atlas-data.json` (decode, view-model load, route LOD,
   place culling, flight arcs, card formatting) and reports median / p95 / min /
   max plus process footprint.
2. **In-app stage marks** — `AtlasPerformance` records launch, decode, store
   ready, tab load, route preparation, and first map appearance. The same stages
   are emitted as `os_signpost` intervals and exposed over Reflex (`perf`).
3. **Frame probe** — on iOS, `FrameProbe` uses a `CADisplayLink` to record the
   interval between presentation callbacks while the map is driven. It reports
   fps, p50/p95/p99/max, and the percentage of frames over 1.5× the target
   interval.

## Running it

```sh
just bench          # headless benchmark on the real snapshot
just bench-compare  # current run vs docs/perf/baseline-headless.json
just bench-baseline # re-record the baseline
```

For the iOS frame probe, build **Release**, install, push the snapshot, and
launch with the dev hooks enabled:

```sh
xcodebuild -project Atlas.xcodeproj -scheme 'Atlas iOS' \
  -configuration Release -destination 'id=<simulator-udid>' build

APP=$(find ~/Library/Developer/Xcode/DerivedData/Atlas-*/Build/Products/Release-iphonesimulator \
  -maxdepth 1 -name 'Atlas iOS.app' | head -1)
xcrun simctl install booted "$APP"
just push-ios-data

SIMCTL_CHILD_ATLAS_REFLEX=1 SIMCTL_CHILD_ATLAS_PERF=1 \
  xcrun simctl launch booted io.ponti.atlas.ios
```

Reflex commands (TCP 18765):

```
perf                 # stage timings, counters, footprint
perf reset           # clear counters before a session
perf frames start    # begin recording display-link intervals
perf frames stop     # stop and print FrameStats JSON
```

The scripted session used for the numbers below: Places → Flights → Walks,
3D on → 3D off, zoom out → zoom in, then one style cycle. A warm-up pass over
every tab, renderer, and style runs first; the measured pass is the second one.

## Baseline (before optimisation)

Snapshot: **7.6 MB**, 92 walks / 87,682 points / 1,550 places / 38 flights.

### Headless, macOS Release

| stage | median |
|---|---:|
| snapshot read | 0.76 ms |
| snapshot decode | **130.29 ms** |
| snapshot load (read + decode) | 130.15 ms |
| snapshot encode | 159.09 ms |
| cold store + tabs load | 131.51 ms |
| route preparation (filter + distance) | 2.79 ms |
| place cull (1,550 → 200) | 1.03 ms |
| flight arcs (38 × 72 points) | 0.10 ms |
| build all 1,550 place cards | 3.00 ms |
| footprint | 82 MB |

### iOS Release, simulator

| metric | baseline |
|---|---:|
| decode | 170.5 ms |
| tab load after decode | 177.0 ms |
| route preparation | 5.0 ms |
| launch → app ready (warm) | 1832 ms |
| session fps | **44.7** |
| p50 | 16.7 ms |
| p95 | 41.1 ms |
| p99 | 82.5 ms |
| max | **758 ms** |
| frames over budget | **16.0 %** |

The session counters showed **11,552 cards built** and **1,840 polylines
submitted** in 13 seconds — both rebuilt from `body`.

## Final

Snapshot: **1.2 MB** (−83%), same 92 walks / 87,682 points / **1,407 places** / 38 flights. Using the desktop app exposed 143 duplicate place rows (escaped-address names and repeated exports); the importer now normalises names and collapses them.

### Headless, macOS Release

| stage | median | delta |
|---|---:|---:|
| snapshot read | 0.07 ms | −91 % |
| snapshot decode | **8.85 ms** | **−93 %** |
| snapshot load | 7.16 ms | −94 % |
| snapshot encode | 9.15 ms | −94 % |
| cold store + tabs load | 7.90 ms | −94 % |
| route preparation (incl. LOD) | 4.50 ms | +61 % (moves work off the render path) |
| route simplification alone | 1.78 ms | — |
| place cull | 0.83 ms | −19 % |
| flight arcs | 0.10 ms | same |
| build all place cards | 2.77 ms | — (now done once, not per frame) |
| footprint | **32 MB** | **−64 %** |

### iOS Release, simulator — warm session

Two consecutive runs after a full warm-up:

| metric | run 1 | run 2 |
|---|---:|---:|
| fps | **58.4** | **58.3** |
| p50 | 16.7 ms | 16.7 ms |
| p95 | **16.7 ms** | **16.7 ms** |
| p99 | 27.5 ms | 33.3 ms |
| max | 107.3 ms | 92.1 ms |
| frames over budget | 1.5 % | 1.3 % |

Warm per-action probes:

| action | fps | p95 | p99 | max |
|---|---:|---:|---:|---:|
| Places | 58.2 | 16.7 | 16.7 | 63.7 |
| Flights | 58.8 | 16.7 | 16.7 | 66.9 |
| Walks | 57.3 | 16.7 | 51.6 | 69.4 |
| 3D on | 58.3 | 16.7 | 16.7 | 68.8 |
| 3D off | 59.2 | 16.7 | 16.7 | 37.0 |
| Zoom out | 58.9 | 16.7 | 16.7 | 41.1 |
| Zoom in | 57.8 | 16.7 | 42.0 | 46.2 |
| Style cycle | 58.1 | 16.7 | 22.1 | 61.2 |

p50 and p95 are exactly the 60 Hz budget (16.7 ms). The remaining misses are a
single ~2–4 frame content-swap cost at the start of an action, not sustained
dropping.

## What changed

1. **Compact route snapshot.** `WalkRoute` now persists coordinates as one
   little-endian `Float32` blob (8 bytes/point, ~1 m precision) and synthesises
   evenly spaced timestamps on read. Per-point timestamps and elevation were
   never rendered and accounted for most of the 7.6 MB file. Legacy `locations`
   arrays still decode.
2. **Decode starts at app init.** `FileAtlasStore.prefetch()` launches a
   detached decode before SwiftUI/MapKit scene setup blocks the main actor.
3. **Cards are cached.** `ContentView` rebuilt all 1,550 place cards (formatted
   strings) on every body pass. Cards now rebuild only when data or the active
   feature changes.
4. **Render inputs leave `body`.** Route overlays, visible places, and flight
   arcs are prepared in `refreshRoutes` / `refreshPlaces` / `refreshArcs` and
   stored in `@State`; `body` only reads them.
5. **Route LOD.** Douglas–Peucker reduces 87,682 points to **4,514** overview
   vertices. The selected route is submitted at full detail; the rest use the
   overview. The overlay set is stable across camera moves, so panning and
   zooming never insert or remove dozens of `MapPolyline`s.
6. **Places are MapKit vector circles.** 200 SwiftUI annotation views (each with
   a tap gesture and shadow) became 80 `MapCircle` overlays; the selected place
   is the only annotation. Cards provide selection.
7. **Camera discipline.** Tab switches and 3D toggles snap instead of animating
   a 0.85 s flyover; large camera moves also snap. Animation is reserved for
   local, user-initiated selections.
8. **Tab switches are one transaction.** The animated tab change was removed so
   MapKit swaps content once instead of being re-evaluated on every animation
   tick.
9. **Place names normalised and deduped.** Exports contained literal `\n` /
   `\,` escapes and comma-appended addresses, producing duplicate cards. The
   importer keeps the venue name and collapses identical name+coordinate rows
   (1,550 → 1,407).

## Instrumentation that made this possible

- `AtlasCore/Sources/AtlasCore/Performance.swift` — `AtlasPerformance` stage
  marks, `os_signpost` intervals, `MetricSummary`, `FrameStats`, the headless
  `AtlasBenchmark`, and `compare(baseline:current:)`.
- `Shared/FrameProbe.swift` — `CADisplayLink` frame cadence on iOS.
- `atlas-cli bench` / `perf` — headless and live inspection.
- `docs/perf/*.json` — raw results. `baseline-*` is pre-optimisation,
  `final-*` and `warm-session-*` are after.

## Live cameras

The Cameras tab is network-backed, so it is deliberately outside the snapshot
benchmark. The page was the worst offender after the first integration: the
camera grid was rebuilt against the viewport on every pan/zoom, the old dock
built 889 cards, and selecting a camera animated a street-level flyover. All
three were removed.

Final measurements (adaptive canvas layer):

| stage | macOS Release, 120 Hz | iOS Release, 60 Hz |
|---|---:|---:|
| tab entry | 110.1 fps, p95 16.7, p99 16.8, max 59 ms | 55.3 fps, p95 16.7, p99 52.1, max 117 ms |
| select camera | 109.1 fps, p95 16.7, p99 21.7, max 32 ms | 56.8 fps, p95 16.7, p99 16.9, max 116 ms |
| locate (grid → dots) | 107.4 fps, p95 16.7, p99 17.9, max 20 ms | 58.6 fps, p95 16.7, p99 33.4, max 37 ms |
| zoom in / out | 111.5 fps, p95 16.7, p99 19.4, max 34 ms | 59.6 fps, p95 16.7, max 33 ms |
| deselect | 114.4 fps, p95 8.3, p99 19.4, max 25 ms | 58.6 fps, p95 16.7, max 33 ms |
| TfL list fetch + decode | 0.7–1.5 s | 0.7–1.5 s |

The two remaining iOS spikes are MapKit's own work, not the camera layer: tab
entry streams the whole-network tileset, and selection decodes the first
snapshot image.

What changed:

1. **Adaptive coverage, drawn on a canvas.** From the overview the layer is a
   12×12 count-weighted grid over the whole network; below ~9 km of latitude
   span it becomes the cameras themselves, culled to the viewport and capped at
   the nearest 200. Both are projected with `MapReader`/`Canvas` fills instead
   of `MapKit` overlays. This matters: the overlay version inserted 144
   `MapCircle`s when the layer activated and cost an **828 ms** frame on iOS.
   The canvas costs one projected ellipse per camera and never touches MapKit's
   content set.
2. **A lazy vertical list.** The sidebar lists all 889 cameras, nearest first,
   in a `LazyVStack`. Only the visible dozen rows are built, so search covers the
   whole network without a render cost. The old horizontal dock could not do
   this: it had to cap at 120 to stay smooth, which silently hid most cameras
   from search.
3. **Selection does not move the camera.** The monitor appears instantly; the
   scope control or the monitor's locate button zooms on request. Closing a card
   no longer refocuses the tab, so deselecting a street-level camera keeps the
   street.
4. **Decode off-main.** The 889-entry TfL payload is parsed on a detached task.
5. **Places culling is tab-scoped.** Panning the camera page no longer culls
   1,407 places that are not visible.
6. **Tappable dots, zero extra frames.** Street-level dots are hit-tested
   against the same projected points the canvas draws (`CameraDotCanvas.dots`),
   and the tap is a `SpatialTapGesture` running alongside MapKit's pan and
   pinch. Measured on iOS Release at 60 Hz: zoom in/out on the camera tab runs
   at **59.8 fps with 0 frames over budget and a 16.7 ms worst frame** — the
   gesture adds no measurable cost. Opening the monitor for the first time
   still decodes the TfL snapshot image once (a single 686 ms frame, warm after
   that: 0 frames over budget).

For comparison, the first camera build submitted all 889 `MapCircle`s and stalled
for **1.8 s** on tab entry.

## Sidebar

The ChatGPT-style sidebar replaced the bottom card dock. It is a real column:
section switcher, live search, and a scrolling list. Performance notes:

- Rows are a `LazyVStack` inside a `ScrollView`, so a 1,407-place or 889-camera
  section builds ~14 row views, not 1,407.
- The panel is a solid dark fill, **not** `.ultraThinMaterial`. The material cost
  a **465 ms** first-open frame on iOS and bought nothing on Mac, where the
  sidebar sits beside the map rather than over it. Removing it dropped the cold
  open to 237 ms and made every later open 58 fps / max 66 ms.
- Search filters the already-built card array in memory; 889 rows filter in
  under a frame (worst 40 ms on macOS, 16.7 ms on iOS).
- Selecting a row scrolls the list to it only when the selection changed from
  outside the list (Reflex or a map tap).
- Cards are no longer rebuilt when a camera is selected, so selection never
  re-formats 889 titles.

## Honest limits

- **Simulator, not device.** Absolute GPU numbers are not representative; the
  relative deltas are. A device run is the next verification step.
- **60 Hz cap here.** p50 = 16.67 ms. A 120 Hz device would halve the target.
- `CADisplayLink` measures presentation cadence, not GPU command-buffer time.
- **One-time first uses remain.** The first Places entry, first 3D entry, and
  first use of each map style can cost 50–120 ms while MapKit builds its
  renderer and streams tiles. Warm entries are clean.
- **Literal 60.0 is not reached.** Sustained fps is 58.3–58.8 across runs with
  1.1–1.6 % of frames over budget, because each action still pays one
  content-swap frame.
  Closing that last gap needs staged overlay/annotation batches or an `MKMapView`
  host with reused annotation views and a prewarmed second map — both larger
  changes than the ones recorded here.
