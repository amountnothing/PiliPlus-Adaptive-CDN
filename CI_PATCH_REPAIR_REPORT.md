# CI Flutter patch repair report

Branch: `fix/ci-flutter-patch-idempotence`

## What changed

- Added `lib/scripts/apply-flutter-patches.sh` (shared by both PR-check jobs).
  - `framework <FLUTTER_ROOT>` applies `lib/scripts/*.patch` minus `*_ios*`.
  - `material <MATERIAL_UI_DIR>` applies `lib/scripts/material/*.patch` minus `*_ios*`.
  - State is classified with `--forward` in both directions:
    forward dry-run OK = apply; forward fails + reverse (`-R --forward`) dry-run OK
    = already applied; anything else (including both succeeding) = incompatible,
    exit 1.
  - Real applies use `--fuzz=0`; output containing `offset` or
    `Hunk #... FAILED` fails the step. A real application is counted only when
    patch prints `patching file`.
  - Prints `total/applied/already_applied/skipped_ios` from classified patches,
    fails on `total == 0` or a tally mismatch, then asserts symbols.
  - `custom` mode plus `PATCH_DIR`/`PATCH_GLOB` allow SDK-free testing.
- Added `lib/scripts/test-apply-flutter-patches.sh`: six deterministic cases
  (old-gate false positive, pristine apply, idempotent re-run, partial tree,
  incompatible tree, symbol-assertion failure). No SDK, no network.
- `.github/workflows/pr-check.yml`: both "Apply Flutter framework patches" and
  "Apply material_ui patches" steps now call the shared script (framework
  first, material_ui second). Job names, triggers, permissions and the unit
  test step are unchanged. Both `Set up Flutter` steps use
  `cache-key: "flutter-v2-:os:-:channel:-:version:-:arch:-:hash:"` with
  `cache: true`, so pre-existing (possibly patched) SDK cache entries are
  unreachable.

### Symbol assertions: one deliberate, documented deviation

The task listed `StandardBottomSheet`, `TabBarState`, `IndicatorPainter`,
`DraggableScrollableSheetState`, `SliverConstrainedCrossAxis_` all under
`$FLUTTER_ROOT/packages/flutter/lib/src/`. In this tree `TabBarState` and
`IndicatorPainter` are introduced by `lib/scripts/material/tabs.patch`
(`+typedef TabBarState = _TabBarState;`, `+typedef IndicatorPainter = _IndicatorPainter;`)
and consumed from `package:material_ui` (`lib/common/widgets/flutter/dyn_tab_bar.dart`
imports it and extends `TabBarState`). They do not exist in the framework patch
set, so asserting them under `$FLUTTER_ROOT` would fail even on a correctly
patched SDK. Therefore:

- framework mode asserts `StandardBottomSheet`, `DraggableScrollableSheetState`,
  `SliverConstrainedCrossAxis_` in `$FLUTTER_ROOT/packages/flutter/lib/src`;
- material mode asserts `TabBarState`, `IndicatorPainter` in the material_ui
  `lib/src`.

This is explained in a comment in the script.

## Commands run and real output

```
$ bash -n lib/scripts/apply-flutter-patches.sh
(no output, exit 0)

$ bash -n lib/scripts/test-apply-flutter-patches.sh
(no output, exit 0)

$ python3 -c "import yaml,sys;yaml.safe_load(open('.github/workflows/pr-check.yml'))"
(no output, exit 0; PyYAML 5.4.1)

$ git diff --check
(no output, exit 0)

$ bash lib/scripts/test-apply-flutter-patches.sh
== case 1: old reverse dry-run gate false positive
PASS: case 1 old gate exits 0 on a pristine tree (false positive documented)
== case 2: pristine tree applies
PASS: case 2 pristine tree applied once
== case 3: second run is idempotent
PASS: case 3 idempotent re-run (no double application)
== case 4: partial tree (one applied, one pristine)
PASS: case 4 partial tree completed correctly
== case 5: incompatible tree fails closed
PASS: case 5 incompatible tree exits 1
== case 6: framework symbol assertion failure
PASS: case 6 framework symbol assertion exits 1

cases: 6 passed, 0 failed
PASS
```

`patch --version` on this host: `GNU patch 2.7.6`.

## Not verified

- No real Flutter SDK was available, so the real `framework`/`material` modes
  were not executed against an actual SDK/material_ui tree; only the offline
  `custom` path and the framework symbol-failure path were exercised.
- No GitHub Actions run was started (nothing was pushed), so the workflow has
  not been observed end-to-end in CI.
- `cache-key` substitution names are used as documented by
  `subosito/flutter-action@v2`; their effect on GitHub's cache was not observed
  locally.
