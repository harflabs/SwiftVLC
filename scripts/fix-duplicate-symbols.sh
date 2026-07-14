#!/usr/bin/env bash
#
# fix-duplicate-symbols.sh — Fix duplicate json symbols in libvlc static libraries
#
# Two VLC plugins (ytdl and chromecast) each compile their own copy of
# json_parse_error and json_read. The Apple linker in Xcode 16+ treats
# duplicate global symbols as errors (especially on Mac Catalyst). This
# script localizes one copy with nmedit so only a single global definition
# remains.
#
# The localization targets the ytdl object, never the chromecast one.
# nmedit rewrites the symbol table of whatever object it edits, which can
# disturb that object's exception-handling sections (__eh_frame,
# __gcc_except_tab, __compact_unwind). The chromecast control object carries
# the C++ catch frames on the cast path (intf_sys_t, reinit,
# ChromecastThread); ytdl is pure C with no exception handling. Editing the
# pure-C copy resolves the duplicate without touching any unwind tables.
#
# Usage:
#   ./scripts/fix-duplicate-symbols.sh path/to/libvlc.xcframework
#   ./scripts/fix-duplicate-symbols.sh path/to/libvlc.a
#   ./scripts/fix-duplicate-symbols.sh --verify path/to/libvlc.xcframework
#
set -euo pipefail

MODE="fix"
if [[ "${1:-}" == "--verify" ]]; then
  MODE="verify"
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--verify] <xcframework-or-static-lib-path>"
  exit 1
fi

TARGET="$1"

verify_macho_archive_alignment() {
  python3 - "$1" <<'PYEOF'
import os
import sys

path = sys.argv[1]
archive_size = os.path.getsize(path)
misaligned = []

with open(path, "rb") as archive:
    if archive.read(8) != b"!<arch>\n":
        raise SystemExit(f"Error: {path} is not a thin archive")

    header_offset = 8
    while header_offset < archive_size:
        archive.seek(header_offset)
        header = archive.read(60)
        if len(header) != 60 or header[58:60] != b"`\n":
            raise SystemExit(
                f"Error: malformed archive header at offset {header_offset} in {path}"
            )

        try:
            member_size = int(header[48:58].decode("ascii").strip())
        except ValueError as error:
            raise SystemExit(
                f"Error: invalid member size at offset {header_offset} in {path}"
            ) from error

        raw_name = header[:16].decode("ascii", errors="replace").strip()
        data_offset = header_offset + 60
        object_offset = data_offset
        member_name = raw_name.rstrip("/")

        if raw_name.startswith("#1/"):
            try:
                name_size = int(raw_name[3:])
            except ValueError as error:
                raise SystemExit(
                    f"Error: invalid extended name at offset {header_offset} in {path}"
                ) from error
            archive.seek(data_offset)
            member_name = archive.read(name_size).rstrip(b"\0").decode(
                "utf-8", errors="replace"
            )
            object_offset += name_size

        archive.seek(object_offset)
        if archive.read(4) in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            if object_offset % 8 != 0:
                misaligned.append((member_name, object_offset))

        next_header = data_offset + member_size
        header_offset = next_header + (next_header % 2)

if misaligned:
    details = ", ".join(f"{name}@{offset}" for name, offset in misaligned[:8])
    raise SystemExit(f"Error: misaligned 64-bit Mach-O archive members in {path}: {details}")
PYEOF
}

count_external_definitions() {
  xcrun nm -g "$1" 2>/dev/null | awk -v symbol="$2" '
    $NF == symbol && $(NF - 1) != "U" { count += 1 }
    END { print count + 0 }
  '
}

verify_thin_archive() {
  local LIB_PATH="$1"
  local ARCH="$2"
  local SYMBOL
  for SYMBOL in _json_parse_error _json_read; do
    local COUNT
    COUNT=$(count_external_definitions "$LIB_PATH" "$SYMBOL")
    if [[ "$COUNT" -ne 1 ]]; then
      echo "Error: $LIB_PATH ($ARCH) has $COUNT external definitions of $SYMBOL; expected 1" >&2
      return 1
    fi
  done
}

verify_static_lib() (
  set -euo pipefail
  local LIB_PATH="$1"
  local WORK_DIR
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-symbol-verify.XXXXXX")
  trap 'rm -rf "$WORK_DIR"' EXIT

  local ARCHS
  read -r -a ARCHS <<< "$(xcrun lipo -archs "$LIB_PATH")"
  if [[ ${#ARCHS[@]} -eq 0 ]]; then
    echo "Error: no architectures found in $LIB_PATH" >&2
    exit 1
  fi

  local ARCH
  for ARCH in "${ARCHS[@]}"; do
    local THIN="${WORK_DIR}/${ARCH}.a"
    if [[ ${#ARCHS[@]} -gt 1 ]]; then
      xcrun lipo -thin "$ARCH" "$LIB_PATH" -output "$THIN"
    else
      cp "$LIB_PATH" "$THIN"
    fi
    verify_thin_archive "$THIN" "$ARCH"
  done
)

fix_static_lib() (
  set -euo pipefail
  local LIB_PATH="$1"
  local WORK_DIR
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-symbols.XXXXXX")
  trap 'rm -rf "$WORK_DIR"' EXIT

  local SYMS_FILE="${WORK_DIR}/localize_syms.txt"
  printf "_json_parse_error\n_json_read\n" > "$SYMS_FILE"

  local ARCHS
  read -r -a ARCHS <<< "$(xcrun lipo -archs "$LIB_PATH")"
  if [[ ${#ARCHS[@]} -eq 0 ]]; then
    echo "Error: no architectures found in $LIB_PATH" >&2
    exit 1
  fi

  local CHANGED=false

  local ARCH
  for ARCH in "${ARCHS[@]}"; do
    local THIN="${WORK_DIR}/${ARCH}.a"
    if [[ ${#ARCHS[@]} -gt 1 ]]; then
      xcrun lipo -thin "$ARCH" "$LIB_PATH" -output "$THIN"
    else
      cp "$LIB_PATH" "$THIN"
    fi

    local PARSE_COUNT READ_COUNT
    PARSE_COUNT=$(count_external_definitions "$THIN" _json_parse_error)
    READ_COUNT=$(count_external_definitions "$THIN" _json_read)
    if [[ "$PARSE_COUNT" -gt 1 || "$READ_COUNT" -gt 1 ]]; then
      local OBJ="libytdl_plugin_la-ytdl.o"
      rm -f "${WORK_DIR}/${OBJ}"
      if ! (cd "$WORK_DIR" && xcrun ar x "$THIN" "$OBJ"); then
        echo "Error: failed to extract $OBJ from $THIN" >&2
        exit 1
      fi
      if [[ ! -f "${WORK_DIR}/${OBJ}" ]]; then
        echo "Error: $OBJ was not found in $THIN" >&2
        exit 1
      fi
      if ! xcrun nmedit -R "$SYMS_FILE" "${WORK_DIR}/${OBJ}"; then
        echo "Error: failed to localize duplicate JSON symbols in $OBJ ($ARCH)" >&2
        exit 1
      fi
      if ! (cd "$WORK_DIR" && xcrun ar r "$THIN" "$OBJ"); then
        echo "Error: failed to replace $OBJ in $THIN" >&2
        exit 1
      fi
      rm -f "${WORK_DIR}/${OBJ}"

      # ar replaces long-name members without preserving the 8-byte object
      # alignment required for 64-bit Mach-O archives. Repack with Apple's
      # static-library tool before lipo combines the architecture slices;
      # otherwise ld rejects the edited ytdl member on macOS.
      local REPACKED="${WORK_DIR}/${ARCH}-repacked.a"
      xcrun libtool -static -a -D -no_warning_for_no_symbols \
        -o "$REPACKED" "$THIN"
      mv "$REPACKED" "$THIN"
      verify_macho_archive_alignment "$THIN"
      CHANGED=true
    fi

    verify_thin_archive "$THIN" "$ARCH"
  done

  if $CHANGED; then
    if [[ ${#ARCHS[@]} -gt 1 ]]; then
      local THIN_FILES=()
      for ARCH in "${ARCHS[@]}"; do
        THIN_FILES+=("${WORK_DIR}/${ARCH}.a")
      done
      xcrun lipo -create "${THIN_FILES[@]}" -output "$LIB_PATH"
    else
      cp "${WORK_DIR}/${ARCHS[0]}.a" "$LIB_PATH"
    fi
    echo "  Fixed: $LIB_PATH"
  fi

  verify_static_lib "$LIB_PATH"
)

process_static_lib() {
  if [[ "$MODE" == "verify" ]]; then
    verify_static_lib "$1"
    echo "  Verified: $1"
  else
    fix_static_lib "$1"
  fi
}

if [[ -d "$TARGET" ]] && [[ "$TARGET" == *.xcframework ]]; then
  find "$TARGET" -name "libvlc.a" -print0 | while IFS= read -r -d '' lib; do
    process_static_lib "$lib"
  done
elif [[ -f "$TARGET" ]] && [[ "$TARGET" == *.a ]]; then
  process_static_lib "$TARGET"
else
  echo "Error: Expected an .xcframework directory or .a file"
  exit 1
fi

echo "Done."
