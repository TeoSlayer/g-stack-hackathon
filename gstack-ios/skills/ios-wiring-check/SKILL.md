---
name: ios-wiring-check
description: Find defined-but-uncalled public symbols — cross-target hooks, doc-promised entry points, dead delegate methods.
---

# /ios-wiring-check

## When to invoke

After a feature has been spec'd-and-implemented but before it's been
end-to-end tested. The motivating case: a bridge class exposes
`publishStatus(...)` for the parent app to call, the doc comment even
says "Call this after every sync" — but `grep` says nothing ever calls
it. The build is green, the tests pass (because there aren't any for
this), and the symptom is "the watch never updates." This skill catches
that class of bug at the wiring layer instead of waiting for a user
complaint.

Wrong call as a general lint pass — too noisy when run blind across a
whole project. Scope to a directory or a recent diff.

## Inputs

Required:
- `roots` — list of source directories to scan. Default: every `Sources/`
  and target directory under the project root.

Optional:
- `scope` — `public-only` (default) or `internal+public`. `private` is
  excluded — it's already covered by the compiler's "unused" warning.
- `since_commit` — git revision; if set, only scan symbols touched in
  commits after this point.
- `whitelist` — list of symbol names known to be called via runtime
  (Interface Builder, `@objc` from Objective-C, dynamic dispatch, etc.).
- `protocols` — list of protocol names whose conformance methods should
  be considered "called by the framework" (e.g. `WCSessionDelegate`,
  `UIApplicationDelegate`).

Assumes:
- Roots are Swift source — Objective-C wiring checking is a separate
  beast.
- `ripgrep` is available (preferred over `grep` for performance and
  type-aware filtering).
- For more accurate parsing than regex, the project may opt in to
  `swift-syntax` via a small helper that emits a JSON declaration index;
  the skill falls back to regex when the helper isn't present.

## Procedure

1. **Extract declarations.** Parse each `.swift` file with a regex pass:
   - `func <name>(...)` at file or type scope.
   - `var <name>:` computed-property declarations.
   - `class <Name>`, `struct <Name>`, `enum <Name>`.
   Capture file:line:symbol:visibility.
2. **Filter** by `scope` — drop `private` and `fileprivate`.
3. **For each remaining symbol,** count references via ripgrep:
   ```
   rg -w "$symbol" --type swift "$roots"
   ```
   Subtract 1 for the declaration line itself. If the result is 0, the
   symbol is **suspected dead**.
4. **Apply false-positive filters:**
   - Skip if `@objc`, `@IBAction`, `@IBOutlet`, `dynamic`, or `override`
     is present on the declaration.
   - Skip if the enclosing type conforms to a protocol in `protocols`
     and the symbol matches a method on that protocol.
   - Skip if the symbol is in `whitelist`.
   - Skip if the symbol is `body`, `init()`, `deinit`, or another known
     framework hook.
   - Skip `@main` entry points.
5. **For each remaining dead symbol,** check its doc-comment. A doc-comment
   that says "Call this when X" or "Used by Y" raises severity — it's not
   just unused, it's *contract-broken*.
6. **Emit report.**

## Outputs

Report (`gstack-ios/.cache/ios-wiring-check-<ts>.json`):
```json
{
  "skill": "ios-wiring-check", "version": "0.1",
  "roots": ["App", "Shared"],
  "scope": "public-only",
  "totals": {"symbols_scanned": 412, "suspected_dead": 3,
             "doc_contract_broken": 1},
  "findings": [
    {"file": "Shared/SessionBridge.swift", "line": 21,
     "symbol": "publishStatus(lastSyncAt:serverReachable:)",
     "visibility": "internal", "refs_outside_self": 0,
     "doc_says": "Call this after every sync or reachability change.",
     "severity": "contract_broken"}
  ],
  "ok": true
}
```

**Side effects:** none.

## Verification

- **Positive:** `ok: true`, every finding has a real file:line, every
  flagged symbol has zero outside-self references when checked manually
  with `rg -w "<symbol>" --type swift`.
- **False-positive review:** the report should be reviewable in under
  30s per finding — if it isn't, the false-positive filters are too
  weak.
- **Negative:** `ok: false` only on input errors (bad roots path).

## Composition

- **Upstream:** none.
- **Downstream:** human review, then issues filed for each
  `contract_broken` finding. `suspected_dead` ones may legitimately be
  cleanup candidates — defer to human judgement.
- **Verifies:** fixes for findings can be confirmed end-to-end by
  `/ios-watch-pair` (for cross-target wiring) or `/ios-test` (for
  in-target wiring).
