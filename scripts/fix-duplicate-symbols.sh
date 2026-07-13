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
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <xcframework-or-static-lib-path>"
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

fix_static_lib() {
  local LIB_PATH="$1"
  local WORK_DIR
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-symbols.XXXXXX")
  trap "rm -rf '$WORK_DIR'" RETURN

  local SYMS_FILE="${WORK_DIR}/localize_syms.txt"
  printf "_json_parse_error\n_json_read\n" > "$SYMS_FILE"

  local LIPO_INFO
  LIPO_INFO=$(lipo -info "$LIB_PATH" 2>/dev/null)
  local ARCHS
  ARCHS=$(echo "$LIPO_INFO" | sed 's/.*: //')
  local IS_FAT=true
  if echo "$LIPO_INFO" | grep -q "Non-fat"; then
    IS_FAT=false
  fi

  local CHANGED=false

  for ARCH in $ARCHS; do
    local THIN="${WORK_DIR}/${ARCH}.a"
    if $IS_FAT; then
      lipo -thin "$ARCH" "$LIB_PATH" -output "$THIN"
    else
      cp "$LIB_PATH" "$THIN"
    fi

    local COUNT
    COUNT=$(nm "$THIN" 2>/dev/null | grep -c 'T _json_parse_error' || true)
    if [[ "$COUNT" -gt 1 ]]; then
      local OBJ="libytdl_plugin_la-ytdl.o"
      (cd "$WORK_DIR" && ar x "$THIN" "$OBJ" 2>/dev/null) || continue
      nmedit -R "$SYMS_FILE" "${WORK_DIR}/${OBJ}" 2>/dev/null || continue
      (cd "$WORK_DIR" && ar r "$THIN" "$OBJ" 2>/dev/null) || continue
      rm -f "${WORK_DIR}/${OBJ}"

      # ar replaces long-name members without preserving the 8-byte object
      # alignment required for 64-bit Mach-O archives. Repack with Apple's
      # static-library tool before lipo combines the architecture slices;
      # otherwise ld rejects the edited ytdl member on macOS.
      local REPACKED="${WORK_DIR}/${ARCH}-repacked.a"
      libtool -static -a -D -no_warning_for_no_symbols \
        -o "$REPACKED" "$THIN"
      mv "$REPACKED" "$THIN"
      verify_macho_archive_alignment "$THIN"
      CHANGED=true
    fi
  done

  if $CHANGED; then
    if $IS_FAT; then
      local THIN_FILES=()
      for ARCH in $ARCHS; do
        THIN_FILES+=("${WORK_DIR}/${ARCH}.a")
      done
      lipo -create "${THIN_FILES[@]}" -output "$LIB_PATH"
    else
      cp "${WORK_DIR}/${ARCHS}.a" "$LIB_PATH"
    fi
    echo "  Fixed: $LIB_PATH"
  fi
}

if [[ -d "$TARGET" ]] && [[ "$TARGET" == *.xcframework ]]; then
  find "$TARGET" -name "libvlc.a" | while read -r lib; do
    fix_static_lib "$lib"
  done
elif [[ -f "$TARGET" ]] && [[ "$TARGET" == *.a ]]; then
  fix_static_lib "$TARGET"
else
  echo "Error: Expected an .xcframework directory or .a file"
  exit 1
fi

echo "Done."
