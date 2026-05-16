# Skill framework

Every skill in `gstack-ios/skills/` is a **refinement protocol**: a repeatable,
inspectable procedure that consumes a project state and produces a sharper one.
Skills are not scripts; scripts are an implementation detail. The skill is the
contract.

## Canonical SKILL.md shape

Each skill lives at `skills/<name>/SKILL.md` and conforms to this shape:

```markdown
---
name: <slash-command name without slash, e.g. ios-build>
description: <one sentence, ≤120 chars, used by humans and by other skills to decide relevance>
status: draft | sharpening | stable
version: 0.x
---

# /<name>

## When to invoke

<2-4 sentences. The signal that says "this skill is the right tool *now*", not
just "this skill is about X". Include negative cases — when it would be wrong.>

## Inputs

<Concrete arguments and the project state assumptions. List required vs optional.
Note assumptions about cwd, env, tooling.>

## Procedure

<Numbered list of steps. Each step must be executable by a fresh agent with no
context. Prefer commands you can paste. State expected exit behaviour at each
step. If a step branches on output, show the branches.>

## Outputs

<What the skill produces. Two flavours, both required:

- **Report**: a structured summary written to stdout / a known file. Define
  the shape (fields, units, ordering). This is what other skills consume.
- **Side effects**: any files written, daemons touched, simulator state
  changed. Enumerate them so callers can roll back.>

## Verification

<How a caller (or the next loop iteration) confirms the skill did its job.
At minimum: a positive check (success looks like X) and a negative check
(failure looks like Y). Prefer machine-checkable.>

## Composition

<Which skills feed into this one (`/ios-xcodegen` before `/ios-build`) and
which consume its output (`/ios-build`'s report is consumed by `/ios-test`,
`/ios-ship-testflight`, etc.). Name them explicitly.>

## Dogfood log

<Append-only list of times this skill was applied to health-sync. Each entry:
date, what was surfaced, link to commit. This is how we know the protocol
pays for itself.>
```

## Status lifecycle

- **draft** — protocol written, not yet dogfooded. Don't depend on it.
- **sharpening** — dogfooded at least once; iterating on the procedure based
  on what real usage exposed. Outputs may still change shape.
- **stable** — dogfooded N≥3 times, output shape frozen, safe to compose.

## Composition rules

1. A skill **may not** call another skill that's `draft`. Force-promote to
   `sharpening` before composing — otherwise the upstream's churn destabilises
   the downstream.
2. Outputs are **structured first, prose second**. Other skills consume the
   structured part; humans read the prose part. Never invert.
3. Side effects are **declared**. A skill that writes files lists them.
   A skill that touches simulators / daemons / `~/.claude` says so. Callers
   need to know the blast radius.
4. **Verification is mandatory**, not aspirational. A skill without
   machine-checkable success criteria is a doc, not a skill.

## Why this shape

- "When to invoke" prevents the skill from being a hammer searching for nails.
- "Procedure" lets a fresh agent execute it without context — which is exactly
  what each loop iteration is.
- "Outputs" is what makes skills composable. Without a defined shape, you have
  prose, which doesn't compose.
- "Verification" is what separates a skill from a wish.
- "Dogfood log" is the receipt. Each entry is evidence the skill earned its
  keep.
