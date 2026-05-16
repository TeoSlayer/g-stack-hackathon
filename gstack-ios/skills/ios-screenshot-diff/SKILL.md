---
name: ios-screenshot-diff
description: Pixel-diff a current screenshot against a baseline with tolerance, highlight regions that changed.
status: draft
version: 0.1
---

# /ios-screenshot-diff

## When to invoke

After a change that *shouldn't* affect a particular screen, to confirm it
hasn't. Pairs with `/ios-simctl screenshot` (the producer of the current
image) and a baseline snapshot saved at a known-good state. Useful for
catching unintentional padding changes, font tweaks, colour drift, asset
swaps.

Wrong call when the screen *is* expected to change — use `/ios-visual-critique`
instead (which is for "is this new screen correct?" rather than "did this
screen change?").

## Inputs

Required:
- `current` — path to the captured screenshot PNG.
- `baseline` — path to the baseline PNG.

Optional:
- `tolerance_pct` — fraction of pixels allowed to differ before flagging.
  Default `0.5` (i.e. 0.5%).
- `tolerance_channel` — per-pixel RGB delta allowed without counting as
  a change. Default `8` (catches anti-aliasing wobble while flagging real
  colour shifts).
- `ignore_regions` — list of `{x, y, w, h}` rectangles to exclude from
  the diff (e.g. timestamp text, animated spinners).
- `out_diff_png` — path to write a visualisation. Default
  `gstack-ios/.cache/diffs/<basename>-diff.png`.

Assumes:
- Both PNGs are the same dimensions. Mismatched dimensions are an immediate
  fail (caller used the wrong device).
- ImageMagick (`compare`) or Python+Pillow available. The skill prefers
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
   The exit code is `0` if identical, `1` if differences within tolerance,
   `2` if error. `AE` (absolute error count) goes to stderr.
4. **Compute pct:** `differing_pixels / (W*H - masked_pixels)`.
5. **Identify diff regions** by running `connected-components` on the
   diff image (white pixels) → list of bounding boxes. Each box gets a
   rough size + centre for the report.
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

Side effects: writes `diff_png` and a transient mask PNG.

## Verification

- **Positive:** `match: true` corresponds to a `diff_png` that is mostly
  black (transparent in the visualisation). `match: false` corresponds to
  a `diff_png` with visible highlights in `regions`.
- **Negative cross-check:** if `match: true` but `regions` is non-empty,
  the tolerances may be too loose — surface a `warning: "match within
  tolerance but N regions differ; consider tighter tolerance for this
  screen"`.
- **Sanity:** dimension mismatch is `ok: false`, not a `match: false` —
  it means the test setup is wrong, not the UI.

## Composition

- **Upstream:** `/ios-simctl screenshot` (current image),
  `/ios-widget-preview` (widget images).
- **Downstream:** `/ios-visual-critique` (when `match: false`, critique
  the differing regions to explain *what* changed in human terms — not
  just "these pixels differ" but "the readiness pill turned from grey to
  green").
- **Baseline management:** there is no skill yet for "promote current to
  baseline". For now, a human commits `<name>-baseline.png` files under
  `health-sync/__snapshots__/` after manual approval. Future skill:
  `/ios-baseline-promote`.

## Dogfood log

*(none yet — needs a captured baseline first; baselines emerge once a
screen has been signed off as visually correct.)*
