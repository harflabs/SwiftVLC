# Aspect harness baseline — pre-fix

Measured on the v0.10.0 binary, iPhone 17 Pro simulator / iOS 26.5, with the
2.40:1 (`testsrc2` 1920×800) fixture in `AspectRatioCase` (16:9 surface,
1110×625 px @3x). `surface_ar` 1.776; the source DAR is 2.40.

| option | picture (px) | picture_ar | corrected target | status |
|--------|--------------|-----------|------------------|--------|
| default | 1110×463 | 2.40 | 2.40 (letterbox) | correct |
| fill    | 1110×463 | 2.40 | ~1.78 (cover) | **A1** — identical to default |
| 16:9    | 1110×463 | 2.40 | 1.78 | **A2** — unchanged |
| 4:3     | 834×347  | 2.40 | 1.33 | **A2** — 2.40 fit *inside* an 833×625 4:3 box |
| 1:1     | 625×261  | 2.40 | 1.00 | **A2** — 2.40 fit *inside* a 625×625 1:1 box |
| 21:9    | 1110×463 | 2.40 | 2.33 | **A2** — unchanged (near-degenerate vs source DAR) |

`assert.py` exits non-zero against this baseline. A1: `.fill` never covers
(the sample-buffer vout ignores `display_fit`). A2: `.ratio(w,h)` letterboxes
the native picture inside a w:h region instead of forcing display aspect.
