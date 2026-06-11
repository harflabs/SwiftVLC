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

fix_static_lib() {
  local LIB_PATH="$1"
  local WORK_DIR
  WORK_DIR=$(mktemp -d)
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
