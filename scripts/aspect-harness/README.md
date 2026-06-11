# Aspect-ratio visual harness

Measures the rendered video rectangle for every `AspectRatio` option by driving
the iOS-simulator Showcase `AspectRatioCase`, so `.fill` (cover) and
`.ratio(w,h)` (forced display aspect) are verified against real pixels rather
than only the libVLC API state. Complements the headless getter-readback
characterization tests in `Tests/SwiftVLCTests/Video/`.

## Why a 2.40:1 fixture
`AspectRatioCase` renders into a 16:9 surface. With 16:9 content, `.default`,
`.fill` and `.ratio(16,9)` are pixel-identical even when correct, so the harness
plays a 2.40:1 clip whose aspect differs from the surface; letterbox, cover and
forced-aspect then produce distinct bounding boxes.

## Run
```sh
# tools (one-time): fb-idb + Pillow in venvs, idb_companion on PATH
idb_companion --udid <SIM_UDID> &
./scripts/aspect-harness/make-fixture.sh /tmp/aspect-240.mp4
# build+install Showcase iOS on the sim first (xcodebuild -scheme iOS ...)
./scripts/aspect-harness/sweep.sh <SIM_UDID> /tmp/aspect-240.mp4 | tee /tmp/sweep.txt
./scripts/aspect-harness/assert.py < /tmp/sweep.txt   # exit 0 = fixed, non-zero = A1/A2 present
```

`measure.py <shot.png> <band_y0_px> <band_y1_px>` reports the surface and
picture bounding boxes (center-cross scan; band isolates the surface between the
About row and the play/pause control). Coordinates are @3x screenshot pixels.

## Baseline (pre-fix, v0.10.0 binary, iPhone 17 Pro / iOS 26.5)
See `BASELINE.md` — `.fill` and every `.ratio` collapse to the 2.40 letterboxed
box, which is what the fixes correct.
