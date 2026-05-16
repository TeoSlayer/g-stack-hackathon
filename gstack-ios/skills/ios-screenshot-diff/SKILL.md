---
name: ios-screenshot-diff
description: Pixel-diff a current screenshot against a baseline with tolerance, highlight regions that changed.
---

# /ios-screenshot-diff

## When to invoke

After a change that *shouldn't* affect a particular screen, to confirm it
hasn't. Pairs with `/ios-simctl screenshot` (the producer of the current
image) and a baseline snapshot saved at a known-good state. Useful for
catching unintentional padding changes, font tweaks, colour drift, asset
swaps.

Wrong call when the screen *is* expected to change — use
`/ios-visual-critique` instead (which is for "is this new screen
correct?" rather than "did this screen change?").

## Inputs

Required:
- `current` — path to the captured screenshot PNG.
- `baseline` — path to the baseline PNG.

Optional:
- `tolerance_pct` — fraction of pixels allowed to differ before flagging.
  Default `0.5` (i.e. 0.5%).
- `tolerance_channel` — per-pixel RGB delta allowed without counting as a
  change. Default `8` (catches anti-aliasing wobble while flagging real
  colour shifts).
- `ignore_regions` — list of `{x, y, w, h}` rectangles to exclude (e.g.
  timestamp text, animated spinners).
- `out_diff_png` — path to write a visualisation. Default
  `gstack-ios/.cache/diffs/<basename>-diff.png`.

Assumes:
- Both PNGs are the same dimensions. Mismatched dimensions are an
  immediate fail (caller used the wrong device).
- ImageMagick (`compare`) or Python+Pillow available. Prefers
  ImageMagick (faster); falls back to Pillow if absent.

## Procedure

1. **Verify both files** exist, are readable PNGs, identical dimensions.
2. **Build effective mask** from `ignore_regions` — composited into a
   binary mask PNG.
3. **Diff via ImageMagick:**
   ```
   compare -metric AE -fuzz <tolerance_channel> \
     -mask ignore_mask.png "$baseline" "$current" "$out_diff_png" \
     2> /tmp/diff_count
   ```
   Exit code: `0` identical, `1` differences within tolerance, `2` error.
   `AE` (absolute error count) goes to stderr.
4. **Compute pct:** `differing_pixels / (W*H - masked_pixels)`.
5. **Identify diff regions** by running connected-components on the diff
   image (white pixels) → list of bounding boxes with size + centre.
6. **Decide pass/fail.** If `pct <= tolerance_pct`, `match: true`.

## Outputs

Report (`gstack-ios/.cache/ios-screenshot-diff-<ts>.json`):
```json
{
  "skill": "ios-screenshot-diff", "version": "0.1",
  "current": "<abs>", "baseline": "<abs>",
  "dimensions": [1179, 2556],
  "tolerance_pct": 0.5, "tolerance_channel": 8,
  "pct_changed": 0.07, "match": true,
  "regions": [
    {"bbox": [120, 1840, 410, 1900], "area_px": 17400,
     "centre": [265, 1870]}
  ],
  "diff_png": "gstack-ios/.cache/diffs/...",
  "ok": true
}
```

**Side effects:** writes `diff_png` and a transient mask PNG.

## Verification

- **Positive:** `match: true` corresponds to a `diff_png` mostly black
  (transparent in the visualisation). `match: false` corresponds to a
  `diff_png` with visible highlights in `regions`.
- **Negative cross-check:** if `match: true` but `regions` is non-empty,
  the tolerances may be too loose — surface a warning.
- **Sanity:** dimension mismatch is `ok: false`, not `match: false` —
  test setup is wrong, not the UI.

## Composition

- **Upstream:** `/ios-simctl screenshot` (current image),
  `/ios-widget-preview` (widget images).
- **Downstream:** `/ios-visual-critique` (when `match: false`,
  critique the differing regions to explain *what* changed in human
  terms — not just "these pixels differ" but "the badge turned from
  grey to green, and the row count went from 3 to 4").
- **Baseline management:** the skill assumes baselines exist on disk
  (a project-level `__snapshots__/` directory by convention). Promoting
  a current screenshot to baseline is a deliberate human act for now.

## On failure → next step

- `match: false` with regions across the whole screen → likely a sim
  device-size change (e.g. running on iPhone 16 against an iPhone 15
  baseline). Confirm `dimensions` match, then either update baseline
  or rebuild on the right device.
- `match: false` with one localised region → run `/ios-visual-critique`
  on the current image with context describing the changed region; the
  critique will explain *what* changed, not just *that* it changed.
- `match: true` but `regions` non-empty → tolerance is too loose for
  this screen. Tighten `tolerance_pct` or `tolerance_channel` and
  re-run.

## Example

```
$ /ios-screenshot-diff \
    current=gstack-ios/.cache/screenshots/iPhone-15-2026-05-16T13-20-00Z.png \
    baseline=__snapshots__/Home-iPhone-15.png

verify dimensions: 1179x2556 == 1179x2556 ✓
compare -metric AE -fuzz 8 ... → 412 differing pixels
pct_changed: 0.014% (under 0.5% tolerance)
match: true
regions: 1
  bbox=[265, 1840, 410, 1900] area=8700px centre=(337, 1870)
diff_png: gstack-ios/.cache/diffs/Home-iPhone-15-diff.png

warning: match within tolerance but 1 region differs.
         If this is the timestamp text, add to ignore_regions.
report: gstack-ios/.cache/ios-screenshot-diff-2026-05-16T13-20-04Z.json
```

When a real regression happens:

```
$ /ios-screenshot-diff current=... baseline=...
pct_changed: 8.7%, match: false
regions: 3 (centres at 590,420 / 590,1840 / 590,2400)

next: /ios-visual-critique screenshots=[<current>, <diff_png>] \
        context="Home screen — diff regions in the badge and the list rows"
```

