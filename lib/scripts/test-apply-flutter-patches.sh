#!/usr/bin/env bash
#
# Offline regression test for apply-flutter-patches.sh.
#
# No Flutter SDK, no network: everything runs against temp fixtures built from
# plain text files and diffs generated with `diff -u`.
#
# It also demonstrates the old gate's false positive (reverse dry-run exits 0
# on a pristine tree because GNU patch silently ignores -R), so that
# misjudgement stays documented.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
APPLY="$SCRIPT_DIR/apply-flutter-patches.sh"

[ -x "$APPLY" ] || {
  echo "FAIL: $APPLY is not executable" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apply-flutter-patches-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

pass_case() {
  echo "PASS: $1"
  pass=$((pass + 1))
}

fail_case() {
  echo "FAIL: $1"
  fail=$((fail + 1))
}

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then
    return 0
  fi
  echo "    expected: $2"
  echo "    actual:   $3"
  return 1
}

assert_grep() { # desc file pattern
  if grep -qE "$3" "$2"; then
    return 0
  fi
  echo "    missing pattern: $3"
  sed 's/^/    | /' "$2" 2>/dev/null | head -20
  return 1
}

assert_same_file() { # desc expected actual
  if diff -u "$2" "$3" >/dev/null 2>&1; then
    return 0
  fi
  echo "    file differs: $3"
  diff -u "$2" "$3" 2>&1 | sed 's/^/    | /' | head -20
  return 1
}

# ---------------------------------------------------------------------------
# Fixtures: two independent one-hunk patches applied with -p1.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/pristine/lib" "$WORK/modified/lib" "$WORK/patches"

printf 'alpha\nbeta\ngamma\ndelta\n' >"$WORK/pristine/lib/thing.txt"
printf 'alpha\nbeta-patched\ngamma\ndelta\n' >"$WORK/modified/lib/thing.txt"

printf 'one\ntwo\nthree\nfour\n' >"$WORK/pristine/lib/other.txt"
printf 'one\ntwo-patched\nthree\nfour\n' >"$WORK/modified/lib/other.txt"

diff -u --label a/lib/thing.txt --label b/lib/thing.txt \
  "$WORK/pristine/lib/thing.txt" "$WORK/modified/lib/thing.txt" \
  >"$WORK/patches/p1.patch" || true
diff -u --label a/lib/other.txt --label b/lib/other.txt \
  "$WORK/pristine/lib/other.txt" "$WORK/modified/lib/other.txt" \
  >"$WORK/patches/p2.patch" || true

if [ ! -s "$WORK/patches/p1.patch" ] || [ ! -s "$WORK/patches/p2.patch" ]; then
  echo "FAIL: could not build fixture patches" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Case 1: old-gate demo (red baseline).
#   On a pristine tree the old reverse dry-run exits 0 while doing nothing.
# ---------------------------------------------------------------------------
echo "== case 1: old reverse dry-run gate false positive"
cp -R "$WORK/pristine" "$WORK/case1"
gate_out="$WORK/gate.out"
if patch -p1 -R --dry-run --batch -d "$WORK/case1" \
  <"$WORK/patches/p1.patch" >"$gate_out" 2>&1; then
  gate_rc=0
else
  gate_rc=$?
fi

ok=1
assert_eq "old gate rc" "0" "$gate_rc" || ok=0
assert_grep "old gate output" "$gate_out" "Unreversed patch detected" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 1 old gate exits 0 on a pristine tree (false positive documented)"
else
  fail_case "case 1 old gate false-positive demo"
fi

# ---------------------------------------------------------------------------
# Case 2: pristine tree -> script applies the patch.
# ---------------------------------------------------------------------------
echo "== case 2: pristine tree applies"
cp -R "$WORK/pristine" "$WORK/case2"
out2="$WORK/case2.out"
if PATCH_DIR="$WORK/patches" PATCH_GLOB='p1.patch' \
  "$APPLY" custom "$WORK/case2" >"$out2" 2>&1; then
  rc2=0
else
  rc2=$?
fi

ok=1
assert_eq "exit code" "0" "$rc2" || ok=0
assert_grep "tally" "$out2" "patches: total=1 applied=1 already_applied=0" || ok=0
assert_same_file "patched content" "$WORK/modified/lib/thing.txt" "$WORK/case2/lib/thing.txt" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 2 pristine tree applied once"
else
  fail_case "case 2 pristine tree applied once"
fi

# ---------------------------------------------------------------------------
# Case 3: same tree again -> already applied, no double application.
# ---------------------------------------------------------------------------
echo "== case 3: second run is idempotent"
out3="$WORK/case3.out"
if PATCH_DIR="$WORK/patches" PATCH_GLOB='p1.patch' \
  "$APPLY" custom "$WORK/case2" >"$out3" 2>&1; then
  rc3=0
else
  rc3=$?
fi
count3="$(grep -c '^beta-patched$' "$WORK/case2/lib/thing.txt" 2>/dev/null || true)"

ok=1
assert_eq "exit code" "0" "$rc3" || ok=0
assert_grep "tally" "$out3" "patches: total=1 applied=0 already_applied=1" || ok=0
assert_eq "patched line count" "1" "$count3" || ok=0
assert_same_file "content unchanged" "$WORK/modified/lib/thing.txt" "$WORK/case2/lib/thing.txt" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 3 idempotent re-run (no double application)"
else
  fail_case "case 3 idempotent re-run (no double application)"
fi

# ---------------------------------------------------------------------------
# Case 4: partial tree -> one applied, one not.
# ---------------------------------------------------------------------------
echo "== case 4: partial tree (one applied, one pristine)"
cp -R "$WORK/pristine" "$WORK/case4"
patch -p1 --forward --batch --fuzz=0 -d "$WORK/case4" \
  <"$WORK/patches/p1.patch" >/dev/null 2>&1 || true

out4="$WORK/case4.out"
if PATCH_DIR="$WORK/patches" PATCH_GLOB='p*.patch' \
  "$APPLY" custom "$WORK/case4" >"$out4" 2>&1; then
  rc4=0
else
  rc4=$?
fi

ok=1
assert_eq "exit code" "0" "$rc4" || ok=0
assert_grep "tally" "$out4" "patches: total=2 applied=1 already_applied=1" || ok=0
assert_same_file "thing content" "$WORK/modified/lib/thing.txt" "$WORK/case4/lib/thing.txt" || ok=0
assert_same_file "other content" "$WORK/modified/lib/other.txt" "$WORK/case4/lib/other.txt" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 4 partial tree completed correctly"
else
  fail_case "case 4 partial tree completed correctly"
fi

# ---------------------------------------------------------------------------
# Case 5: incompatible tree -> fail closed.
# ---------------------------------------------------------------------------
echo "== case 5: incompatible tree fails closed"
cp -R "$WORK/pristine" "$WORK/case5"
printf 'unrelated\ncontext\n' >"$WORK/case5/lib/thing.txt"

out5="$WORK/case5.out"
if PATCH_DIR="$WORK/patches" PATCH_GLOB='p1.patch' \
  "$APPLY" custom "$WORK/case5" >"$out5" 2>&1; then
  rc5=0
else
  rc5=$?
fi

ok=1
assert_eq "exit code" "1" "$rc5" || ok=0
assert_grep "diagnostic" "$out5" "INCOMPATIBLE patch" || ok=0
assert_grep "patch path" "$out5" "p1\.patch" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 5 incompatible tree exits 1"
else
  fail_case "case 5 incompatible tree exits 1"
fi

# ---------------------------------------------------------------------------
# Case 6: framework symbol assertion failure -> fail closed.
# ---------------------------------------------------------------------------
echo "== case 6: framework symbol assertion failure"
cp -R "$WORK/pristine" "$WORK/case6"
mkdir -p "$WORK/case6/packages/flutter/lib/src"

out6="$WORK/case6.out"
if PATCH_DIR="$WORK/patches" PATCH_GLOB='p1.patch' \
  "$APPLY" framework "$WORK/case6" >"$out6" 2>&1; then
  rc6=0
else
  rc6=$?
fi

ok=1
assert_eq "exit code" "1" "$rc6" || ok=0
assert_grep "missing symbols" "$out6" "patched symbols missing" || ok=0
assert_grep "missing symbol name" "$out6" "StandardBottomSheet" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 6 framework symbol assertion exits 1"
else
  fail_case "case 6 framework symbol assertion exits 1"
fi

# ---------------------------------------------------------------------------
# Case 7: benign line offset -> still applied, offset accepted.
#   Prepending unrelated lines moves the hunk, so GNU patch reports an offset
#   while the context still matches exactly under --fuzz=0.
#   The patch needs a hunk that does not start at line 1: GNU patch does not
#   fall forward to a later match for a hunk anchored at the very first line.
# ---------------------------------------------------------------------------
echo "== case 7: line offset is accepted"
mkdir -p "$WORK/offset-base/lib" "$WORK/offset-mod/lib" "$WORK/case7/lib"
printf 'h1\nh2\nh3\nalpha\nbeta\ngamma\ndelta\n' >"$WORK/offset-base/lib/thing.txt"
printf 'h1\nh2\nh3\nalpha\nbeta-patched\ngamma\ndelta\n' >"$WORK/offset-mod/lib/thing.txt"
diff -u --label a/lib/thing.txt --label b/lib/thing.txt \
  "$WORK/offset-base/lib/thing.txt" "$WORK/offset-mod/lib/thing.txt" \
  >"$WORK/patches/offset.patch" || true
{
  for i in 1 2 3 4 5 6; do
    echo "filler-$i"
  done
  cat "$WORK/offset-base/lib/thing.txt"
} >"$WORK/case7/lib/thing.txt"

out7="$WORK/case7.out"
if PATCH_DIR="$WORK/patches" PATCH_GLOB='offset.patch' \
  "$APPLY" custom "$WORK/case7" >"$out7" 2>&1; then
  rc7=0
else
  rc7=$?
fi
count7="$(grep -c '^beta-patched$' "$WORK/case7/lib/thing.txt" 2>/dev/null || true)"
first7="$(head -1 "$WORK/case7/lib/thing.txt")"

ok=1
assert_eq "exit code" "0" "$rc7" || ok=0
assert_grep "tally" "$out7" "patches: total=1 applied=1 already_applied=0" || ok=0
assert_grep "offset note" "$out7" "offset" || ok=0
assert_grep "accepted note" "$out7" "line offset accepted" || ok=0
assert_eq "patched line count" "1" "$count7" || ok=0
assert_eq "prepended content preserved" "filler-1" "$first7" || ok=0
if [ "$ok" -eq 1 ]; then
  pass_case "case 7 benign line offset applied once"
else
  fail_case "case 7 benign line offset applied once"
fi

# ---------------------------------------------------------------------------
echo
echo "cases: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "FAIL"
  exit 1
fi
echo "PASS"
