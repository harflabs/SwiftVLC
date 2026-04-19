#!/usr/bin/env bash
#
# Reports documentation coverage for SwiftVLC's public API.
#
# Emits the module's symbol graph via swift-symbolgraph-extract (bundled
# with every Swift toolchain), then walks every public symbol and
# reports the ones whose doc comment is missing. Compiler-synthesized
# symbols (e.g. Hashable's `hash(into:)` via raw-value synthesis) have
# no source location and are skipped — they're not ours to document.
#
# Exit codes:
#   0 — all public, non-synthesized symbols are documented
#   1 — one or more symbols are missing docs
#
# Usage:
#   ./scripts/doc-coverage.sh            # report + summary
#   ./scripts/doc-coverage.sh --json     # emit JSON (for CI consumption)

set -euo pipefail

MODULE="SwiftVLC"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

# xcrun respects $TOOLCHAINS when CI pins a specific Swift toolchain.
xcrun swift build --target "$MODULE" >/dev/null

# Derive target triple and build layout from the active toolchain / SwiftPM
# rather than hard-coding `arm64-apple-macosx15.0` + `.build/arm64-apple-macosx/…`.
# Hard-coded paths break on Intel runners and future SwiftPM layouts.
TARGET="$(xcrun swiftc -print-target-info \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')"
BIN_DIR="$(xcrun swift build --target "$MODULE" --show-bin-path)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODULES_DIR="$BIN_DIR/Modules"
FRAMEWORKS_DIR="$BIN_DIR/PackageFrameworks"

xcrun swift-symbolgraph-extract \
  -module-name "$MODULE" \
  -target "$TARGET" \
  -sdk "$SDK" \
  -I "$MODULES_DIR" \
  -I Sources/CLibVLC/include \
  -F "$FRAMEWORKS_DIR" \
  -minimum-access-level public \
  -output-dir "$OUT_DIR" >/dev/null

/usr/bin/python3 - "$OUT_DIR/$MODULE.symbols.json" "${1:-}" <<'PY'
import json, pathlib, collections, sys

path = pathlib.Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else ""
data = json.loads(path.read_text())

# Symbol kinds that should carry a doc comment.
DOC_REQUIRED_KINDS = {
    "swift.class", "swift.struct", "swift.enum", "swift.protocol",
    "swift.func", "swift.method", "swift.init",
    "swift.var", "swift.property", "swift.type.property", "swift.type.method",
    "swift.subscript", "swift.enum.case", "swift.typealias",
}

documented = 0
undocumented = []
synthesized_skipped = 0
by_file = collections.defaultdict(list)

for sym in data["symbols"]:
    kind = sym["kind"]["identifier"]
    if kind not in DOC_REQUIRED_KINDS:
        continue
    loc = sym.get("location", {})
    uri = loc.get("uri")
    # Symbols without a source location are compiler-synthesized
    # (protocol conformance fills like Hashable's hash(into:)). They
    # inherit the protocol's documentation, so don't flag them.
    if not uri:
        synthesized_skipped += 1
        continue
    qname = ".".join(sym["pathComponents"])
    line = loc.get("position", {}).get("line", 0) + 1
    if sym.get("docComment") and sym["docComment"].get("lines"):
        documented += 1
    else:
        undocumented.append((uri, line, kind, qname))
        by_file[uri].append((line, kind, qname))

total = documented + len(undocumented)
pct = (documented / total * 100) if total else 100.0

if mode == "--json":
    print(json.dumps({
        "total": total,
        "documented": documented,
        "undocumented": len(undocumented),
        "coverage_percent": round(pct, 2),
        "synthesized_skipped": synthesized_skipped,
        "gaps": [
            {"file": u, "line": l, "kind": k, "symbol": q}
            for (u, l, k, q) in undocumented
        ],
    }, indent=2))
else:
    print(f"Public symbols: {total}")
    print(f"Documented:     {documented}")
    print(f"Undocumented:   {len(undocumented)}")
    print(f"Coverage:       {pct:.1f}%")
    print(f"Synthesized skipped: {synthesized_skipped}")
    if undocumented:
        print()
        print("Undocumented symbols:")
        for uri, items in sorted(by_file.items()):
            short = uri.split("swiftvlc/")[-1] if "swiftvlc/" in uri else uri
            print(f"  {short}")
            for line, kind, qname in sorted(items):
                print(f"    L{line:<4} {kind:<22} {qname}")

sys.exit(0 if not undocumented else 1)
PY
