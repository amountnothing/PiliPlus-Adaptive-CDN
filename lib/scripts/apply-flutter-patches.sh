#!/usr/bin/env bash
#
# Apply this fork's in-tree patch sets to a target tree, fail-closed.
#
# Usage:
#   lib/scripts/apply-flutter-patches.sh framework <FLUTTER_ROOT>
#   lib/scripts/apply-flutter-patches.sh material  <MATERIAL_UI_DIR>
#   lib/scripts/apply-flutter-patches.sh custom    <TARGET_DIR>
#
#   framework : apply lib/scripts/*.patch (minus *_ios*) to the Flutter SDK,
#               then assert the framework symbols this fork's Dart code needs.
#   material  : apply lib/scripts/material/*.patch (minus *_ios*) to the
#               resolved material_ui package, then assert its symbols.
#   custom    : apply PATCH_DIR/PATCH_GLOB to TARGET_DIR, no symbol assertions.
#               Intended for the offline regression test; no SDK required.
#
# Environment overrides (mainly for tests):
#   PATCH_DIR   directory containing the patch files
#               (default: this script's directory for framework,
#                <script dir>/material for material; required for custom)
#   PATCH_GLOB  glob inside PATCH_DIR (default: *.patch)
#
# Patch state is classified with --forward in BOTH directions:
#
#   `patch -R --dry-run --batch` alone is NOT a reliable "already applied?"
#   probe. On a pristine tree GNU patch sees that the patch is not reversed,
#   silently ignores -R and still exits 0 ("Unreversed patch detected!
#   Ignoring -R."). Gating on that rc made every patch look pre-applied on a
#   pristine SDK cache miss, so nothing was applied and the build failed later
#   in lib/. --forward forbids that auto-correction: a forward dry-run
#   succeeds only on a pristine tree, a reverse dry-run succeeds only on an
#   applied tree.
#
#   FORWARD     forward dry-run rc 0  -> apply for real, count only when
#                                       patch reports "patching file"
#   APPLIED     forward fails, reverse dry-run rc 0 -> skip
#   otherwise   INCOMPATIBLE -> print the patch and the patch output, exit 1
#
# Real applies use --fuzz=0 and reject "offset"/"FAILED" output: strict hunks,
# no guessing. The final tally is derived from classified patches, never from
# loop iterations, and is cross-checked before the symbol assertions run.

set -euo pipefail

usage() {
  sed -n '3,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

MODE="${1:-}"
TARGET="${2:-}"

case "$MODE" in
  framework|material|custom) ;;
  *)
    printf 'ERROR: unknown or missing mode: %s\n' "${MODE:-<none>}" >&2
    usage
    exit 1
    ;;
esac

[ -n "$TARGET" ] || die "missing target directory (see usage)"
[ -d "$TARGET" ] || die "target directory not found: $TARGET"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

case "$MODE" in
  framework) DEFAULT_PATCH_DIR="$SCRIPT_DIR" ;;
  material)  DEFAULT_PATCH_DIR="$SCRIPT_DIR/material" ;;
  custom)    DEFAULT_PATCH_DIR="" ;;
esac

PATCH_DIR="${PATCH_DIR:-$DEFAULT_PATCH_DIR}"
PATCH_GLOB="${PATCH_GLOB:-*.patch}"

[ -n "$PATCH_DIR" ] || die "custom mode requires PATCH_DIR"
[ -d "$PATCH_DIR" ] || die "patch directory not found: $PATCH_DIR"

work="$(mktemp -d "${TMPDIR:-/tmp}/apply-flutter-patches.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fwd_out="$work/forward.out"
rev_out="$work/reverse.out"
apply_out="$work/apply.out"

incompatible() {
  local p="$1" reason="$2"
  {
    printf 'INCOMPATIBLE patch: %s\n' "$p"
    printf 'reason: %s\n' "$reason"
    printf -- '--- forward dry-run ---\n'
    cat "$fwd_out" 2>/dev/null || true
    printf -- '--- reverse dry-run ---\n'
    cat "$rev_out" 2>/dev/null || true
  } >&2
  exit 1
}

shopt -s nullglob
matched=("$PATCH_DIR"/$PATCH_GLOB)
shopt -u nullglob

selected=()
skipped_ios=0
for p in "${matched[@]}"; do
  name="$(basename "$p")"
  if [ "$MODE" != "custom" ]; then
    case "$name" in
      *_ios*)
        echo "skip (iOS only): $p"
        skipped_ios=$((skipped_ios + 1))
        continue
        ;;
    esac
  fi
  selected+=("$p")
done

total="${#selected[@]}"
applied=0
already_applied=0

for p in "${selected[@]}"; do
  if patch -p1 --dry-run --forward --batch --fuzz=0 -d "$TARGET" <"$p" >"$fwd_out" 2>&1; then
    forward_ok=1
  else
    forward_ok=0
  fi

  if patch -p1 -R --dry-run --forward --batch --fuzz=0 -d "$TARGET" <"$p" >"$rev_out" 2>&1; then
    reverse_ok=1
  else
    reverse_ok=0
  fi

  if [ "$forward_ok" -eq 1 ] && [ "$reverse_ok" -eq 1 ]; then
    incompatible "$p" "both forward and reverse dry-runs succeeded (ambiguous state)"
  elif [ "$forward_ok" -eq 1 ]; then
    echo "== applying $p"
    if ! patch -p1 --forward --batch --fuzz=0 -d "$TARGET" <"$p" >"$apply_out" 2>&1; then
      cat "$apply_out" >&2 || true
      incompatible "$p" "forward dry-run passed but the real apply failed"
    fi
    cat "$apply_out"

    if ! grep -qF 'patching file' "$apply_out"; then
      incompatible "$p" "real apply exited 0 without reporting 'patching file'"
    fi
    if grep -qE 'offset|Hunk #[0-9]+ FAILED' "$apply_out"; then
      incompatible "$p" "patch applied with fuzz/offset or a failed hunk"
    fi
    applied=$((applied + 1))
  elif [ "$reverse_ok" -eq 1 ]; then
    echo "already applied: $p"
    already_applied=$((already_applied + 1))
  else
    incompatible "$p" "neither forward nor reverse dry-run applies cleanly"
  fi
done

printf '%s patches: total=%d applied=%d already_applied=%d skipped_ios=%d\n' \
  "$MODE" "$total" "$applied" "$already_applied" "$skipped_ios"

[ "$total" -gt 0 ] || die "no patches matched $PATCH_DIR/$PATCH_GLOB"
if [ $((applied + already_applied)) -ne "$total" ]; then
  die "tally mismatch: applied($applied) + already_applied($already_applied) != total($total)"
fi

assert_symbols() {
  local root="$1"
  shift
  local missing=()
  local s
  for s in "$@"; do
    if ! grep -rqF --include='*.dart' -- "$s" "$root" 2>/dev/null; then
      missing+=("$s")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    {
      printf 'ERROR: patched symbols missing under %s\n' "$root"
      printf '  - %s\n' "${missing[@]}"
    } >&2
    exit 1
  fi
  printf 'symbol check ok under %s: %s\n' "$root" "$*"
}

# NOTE: TabBarState and IndicatorPainter are introduced by
# lib/scripts/material/tabs.patch, not by the framework patch set, and live in
# the material_ui package tree. Asserting them under $FLUTTER_ROOT would fail
# even on a correctly patched SDK, so they are asserted in material mode.
case "$MODE" in
  framework)
    symbol_root="$TARGET/packages/flutter/lib/src"
    [ -d "$symbol_root" ] || die "framework source tree not found: $symbol_root"
    assert_symbols "$symbol_root" \
      StandardBottomSheet \
      DraggableScrollableSheetState \
      SliverConstrainedCrossAxis_
    ;;
  material)
    [ -d "$TARGET/lib/src" ] || die "material_ui source tree not found: $TARGET/lib/src"
    assert_symbols "$TARGET/lib/src" \
      TabBarState \
      IndicatorPainter
    ;;
  custom)
    echo "symbol assertions skipped (custom mode)"
    ;;
esac
