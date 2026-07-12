#!/usr/bin/env python3
"""Reads `sweep.sh` output (lines "<opt> <json>") and asserts the corrected
aspect geometry: .fill covers the surface, and .ratio(w,h) forces the picture
to the requested display aspect. Exits non-zero with a report if any case is
wrong (the failing state on a binary without the aspect cover/stretch fixes)."""
import sys, json

SURFACE_AR = 16 / 9
TARGET = {  # picture aspect each option must produce in a 16:9 surface
    "fill": ("cover", SURFACE_AR),   # picture aspect ~= surface aspect (full cover)
    "r169": ("ar", 16 / 9),
    "r43":  ("ar", 4 / 3),
    "r11":  ("ar", 1.0),
    "r219": ("ar", 21 / 9),
}
TOL = 0.06

rows = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    opt, _, blob = line.partition(" ")
    rows[opt] = json.loads(blob)

ok = True
default_ar = rows.get("default", {}).get("picture_ar")
print(f"default picture_ar={default_ar} (source DAR, letterboxed) surface_ar={rows.get('default',{}).get('surface_ar')}")
for opt, (kind, want) in TARGET.items():
    row = rows.get(opt)
    if not row or row.get("picture_ar") is None:
        print(f"FAIL {opt}: no measurement"); ok = False; continue
    got = row["picture_ar"]
    target = want
    passed = abs(got - target) <= TOL
    if kind == "cover":
        # also reject the letterboxed-equals-default state explicitly
        passed = passed and abs(got - (default_ar or 0)) > TOL
    print(f"{'PASS' if passed else 'FAIL'} {opt}: picture_ar={got} target~{round(target,3)}")
    ok = ok and passed

sys.exit(0 if ok else 1)
