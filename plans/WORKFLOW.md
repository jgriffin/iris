# Project Planning Workflow

A lightweight file structure for keeping Claude Code (and your future self) on task across work blocks. This document lives at `plans/WORKFLOW.md` and is referenced from `CLAUDE.md`.

## Directory layout

```
CLAUDE.md                    # constitution: stack, conventions, invariants
plans/
  WORKFLOW.md                # this document — how the planning files work
  BRIEF.md                   # north star: what & why (1 page, rarely changes)
  STATUS.md                  # at-a-glance snapshot: milestone tree, the one next, open Qs (links to sources)
  DECISIONS.md               # settled questions, with refs to explorations
  QUESTIONS.md               # open questions with lifecycle tags
  LOG.md                     # append-only work-block journal
  features/                  # working plans for milestones & big features
    <slug>.md                # scope, phases, opens, risks; lifetime ~ that work
explorations/
  YYYY-MM-DD-topic/
    QUESTIONS.md             # questions driving this exploration
    <whatever work files>    # notes, experiments, data, scratch
    SYNTHESIS.md             # options and tradeoffs, distilled
    RECOMMENDATIONS.md       # what to do, feeds DECISIONS.md
```

Capitalized filenames mark files that participate in the formal process. Lowercase files inside an exploration folder are working material — anything goes.

## What goes where

The rule: match the file to the **volatility** of the content.

| File             | Changes      | Contains                                                                                |
| ---------------- | ------------ | --------------------------------------------------------------------------------------- |
| `CLAUDE.md`      | rarely       | invariants that constrain all future code                                               |
| `BRIEF.md`       | rarely       | problem, success criteria, non-goals                                                    |
| `STATUS.md`      | per block    | derived snapshot dashboard — milestone/phase tree, the one `👉 next`, rolled-up open questions & decisions; links to each source of truth. Rewritten (not appended) each block. |
| `DECISIONS.md`   | per decision | dated paragraphs with enough context to act on; link to exploration RECOMMENDATIONS.md for the deep case |
| `QUESTIONS.md`   | per question | `[open]` / `[exploring]` / `[answered]`                                                 |
| `LOG.md`         | per block    | append-only, dated headers                                                              |
| `features/<slug>.md` | per phase | working plan for a milestone or big feature — scope, phase breakdown, opens, risks. Lifetime tracks the work; delete or supersede when the work closes (LOG.md keeps the trail). |

If you're tempted to add something to CLAUDE.md, ask: *does this constrain how code gets written, forever?* If no, it belongs somewhere in `plans/`.

**File references should be clickable markdown links** — both within `plans/` (e.g. `[`DECISIONS.md`](./DECISIONS.md)`) and out to explorations (e.g. `[`explorations/.../RECOMMENDATIONS.md`](../explorations/...)`). It's much easier to navigate a workflow when every cross-reference is one click away.

## Status trees

`plans/STATUS.md` is the project's `git status` — where work stands right now,
rewritten each block (`LOG.md` is the history). It's built from two reusable
components — the **focus tree** and the **overview tree** — that also appear in
handoffs and inline whenever you ask *"what's next?"*. They're building blocks,
not whole answers: a reply leads with the right tree, then adds the recommendation
and an offer. Annotate `LOG.md` entries, `QUESTIONS.md` tags, and
`features/<slug>.md` phase headings with the same vocabulary.

One shared vocabulary — a readiness→growth lifecycle:

```
✏️ penciled in ──define──▶ 📋 defined ──start──▶ 🌱 in-progress ──▶ ✅ done
```

- ✏️ **penciled in** — wanted but tentative and undefined (no brief, questions open). Picking it up means **defining it first**.
- 📋 **defined** — scoped, questions answered, ready to hand off to an agent.
- 🌱 **in-progress** — actively growing.  ✅ **done** · ⏸ **paused** · 🚫 **abandoned**.
- Markers (ride alongside, not states): 👉 next · ❓ open question · ⚖️ needs decision · 💡 idea/learned · 📌 decided/answered · 👀 needs verification · ℹ️ note · 🚩 issue · 🗓 deferred.

### Focus tree

The active milestone and its phases — nothing else. The mid-work view: *until this
is done, this is the status.* No older milestones, no penciled-in ideas. The
milestone is the root line; its phases hang beneath.

```
🌱 M5 — Dataset
├─ ✅ P1 — DatasetSink protocol
├─ 🌱 P2 — COCO sidecar writer     ← here
└─ 📋 P3 — curation affordances

👉 next  finish P2 — write the sidecar encoder + fixture test
```

### Overview tree

The whole map: every defined milestone, one line each (the active one expands into
its phases — that's the focus tree, embedded), with penciled-in ideas in a
delineated zone below. The boundary / big-picture view. At a clean boundary
(nothing active) it looks like this:

```
Iris · overview tree · 2026-05-24
├─ ✅ M1 — Capture core
├─ ✅ M2 — Detection + overlay
├─ ✅ M3 — Playback
└─ ✅ M4 — Tuning            (P1–P3 ✅ · P4 🚫)

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M5 — Dataset (BRIEF §6)            ← likely next
   ✏️ M6 — Custom models + captioning (BRIEF §7)

👉 next  define M5 → draft features/M5.md (discuss-phase)
```

When a milestone is active, its node expands like the focus tree:

```
└─ 🌱 M5 — Dataset
   ├─ ✅ P1 — DatasetSink protocol
   ├─ 🌱 P2 — COCO sidecar writer     ← here
   └─ 📋 P3 — curation affordances
```

### Rules

1. A milestone earns a place **in the tree** (`├─`/`└─`) only once it's **defined**
   — its `features/<slug>.md` brief exists. Until then it's ✏️ penciled in, in the
   zone below. The tree structure *is* the signal: this is the agreed skeleton.
2. `📋` and `🌱` appear only inside the tree (a defined milestone or its phases);
   `✏️` appears only in the penciled-in zone.
3. The readiness axis cascades: defining a milestone produces its phases, each
   itself ✏️ or 📋. A defined milestone can still hold ✏️ work — define before building.
4. Penciled-in zone (overview only): flat list, `✏️ <name> (<source>)`. The source
   is shown because ideas come from different places — `BRIEF`, a future
   `roadmap.md`, an answered question — not one approved path. `← likely next`
   marks the front-runner.
5. Exactly one *live* 👉 **next**, always last. Advancing consumes it (move it,
   don't append); past blocks' logged `Next:` lines are frozen history. At a
   boundary it names the **define-gate** ("define M5"), not the work.
6. One line per item, identical every time — no horizontal stacking. Predictability
   is the whole point.

### Surfacing status in conversation

Lead with the trees when reporting, not only in `STATUS.md`:

- **"what's next?" (and kin)** → lead with the tree that fits: the **focus tree** if
  a milestone is active, the **overview tree** at a boundary. *Which tree appears is
  itself the signal* of where we are. Then the recommended move + an offer.
- **Mid-block check-in** → the focus tree.
- **Asking questions** → tag each item 👀 (needs your verification) or ℹ️ (just a note).
- **Clear-point / handoff** → the overview tree + the single 👉 next.

## Lifecycle

```
question arises        → plans/QUESTIONS.md [open]
need to investigate    → explorations/YYYY-MM-DD-topic/QUESTIONS.md
                         plans/QUESTIONS.md → [exploring]
work happens           → whatever files needed inside exploration folder
exploration wraps      → SYNTHESIS.md (options, tradeoffs)
                         RECOMMENDATIONS.md (what to do)
decision made          → plans/DECISIONS.md (refs RECOMMENDATIONS.md)
                         plans/QUESTIONS.md → [answered]
affects all code       → CLAUDE.md
end of work block      → append plans/LOG.md
                         rewrite plans/STATUS.md + advance the one 👉 next
```

## CLAUDE.md hookup

Add this block near the top of `CLAUDE.md` so Claude Code wires into the workflow:

```markdown
## Project workflow

This project uses the planning structure described in `plans/WORKFLOW.md`. Read it before making non-trivial changes. In short:

- `plans/STATUS.md` — where work stands now (read first); rewrite at the end of each block
- `plans/BRIEF.md` — what & why
- `plans/DECISIONS.md` — settled questions (check before proposing architectural changes)
- `plans/QUESTIONS.md` — open questions (land new ones here, don't speculate in code)
- `plans/LOG.md` — append a dated entry at the end of each work block
- `explorations/YYYY-MM-DD-topic/` — investigations that wrap with `SYNTHESIS.md` and `RECOMMENDATIONS.md`
```

## File templates

### `plans/BRIEF.md`

```markdown
# <Project name>

## Problem
<1–3 sentences. What is this solving?>

## Success criteria
- <Concrete, observable outcome>
- <Another>

## Non-goals
- <What this is explicitly not>

## Constraints
- <Hardware, time, dependencies>
```

### `plans/DECISIONS.md`

```markdown
# Decisions

<!-- Newest at top. Each entry: short title with date, a paragraph that captures
     the decision clearly enough to act on without opening the reference, then a
     link to the exploration that justifies it. Leave a blank line between entries.
     The linked RECOMMENDATIONS.md carries the deep case — don't restate it here. -->

### 2026-05-21 — Use MPS over CPU for inference

Switch the training loop and replay-buffer reads to MPS despite the float64 →
float32 conversion at load time. The per-step gain on Apple Silicon more than
offsets the one-time conversion cost. CPU fallback is kept for tests where
exact-float comparisons matter.

→ [`explorations/2026-05-20-mps-vs-cpu/RECOMMENDATIONS.md`](../explorations/2026-05-20-mps-vs-cpu/RECOMMENDATIONS.md)

### 2026-05-19 — Replay buffer stays on CPU

Buffer lives in CPU memory; batches transfer to MPS at sample time. Keeping the
buffer device-agnostic preserves the option to swap accelerators later without
touching the storage layer.

### 2026-05-15 — Project name is "cubelet"

Short, no PyPI collision, evokes the cube-shaped state-action grid the agent
operates on. Considered "rubric" (taken) and "tessera" (too obscure).
```

The shape: an `### YYYY-MM-DD — Short title` header, one paragraph that gives a reader enough to act without opening the link, and a `→ link` to the source. Skip the link when the decision is self-evident (naming, scope calls). When the rationale matters, link the exploration's `RECOMMENDATIONS.md` (or `BRIEF.md`, or wherever the case lives) rather than restating it here.

### `plans/QUESTIONS.md`

```markdown
# Open questions

<!-- Status tags: [open] [exploring] [answered DATE]. File references should be clickable markdown links. -->

- [open] <question>
- [exploring] <question> — see [`explorations/2026-05-21-foo/`](../explorations/2026-05-21-foo/)
- [answered 2026-05-19] <question> — see [`DECISIONS.md`](./DECISIONS.md)
```

### `plans/STATUS.md`

The overview tree is the headline; links point to the source of truth, never copy
it. One 👉 next, always last. (See "Status trees" above for the full format.)

```markdown
# <Project> — Status
_Snapshot · <date>_

├─ ✅ M1 — <name>
├─ 🌱 M2 — <name>
│  ├─ ✅ P1 — <name>
│  └─ 🌱 P2 — <name>     ← here
└─ 📋 M3 — <name>

penciled in — not yet defined (ideas, traceable to you)
   ✏️ M4 — <name> (<source>)     ← likely next

👉 next  <the one thing>. → [`LOG.md`](./LOG.md)

❓ open → [`QUESTIONS.md`](./QUESTIONS.md)   ·   📌 recent → [`DECISIONS.md`](./DECISIONS.md)
```

### `plans/LOG.md`

```markdown
# Work log

<!-- STATUS · snapshot, rewritten each block · full board in STATUS.md -->
🌱 **M2 — <name>** (P1 ✅ · P2 🌱 ← here)
👉 Next: <the one thing>. → [`STATUS.md`](./STATUS.md)
<!-- /STATUS -->

---
<!-- Below: append-only, newest at bottom. -->

## 2026-05-21
- Did: <thing>
- 💡 Learned: <thing>
- 🗓 Deferred: <thing>
- 👉 Next: <thing>
```

### `explorations/YYYY-MM-DD-topic/QUESTIONS.md`

```markdown
# Questions driving this exploration

- <The primary question being investigated>
- <Sub-questions that came up along the way>
```

These are scoped to the exploration — distinct from `plans/QUESTIONS.md` which tracks project-wide open questions.

### `explorations/YYYY-MM-DD-topic/SYNTHESIS.md`

```markdown
# Synthesis: <topic>

## Context
<What was investigated and why>

## Options considered
### Option A: <name>
- <Key details>
- Pros: …
- Cons: …

### Option B: <name>
- …

## Key tradeoffs
- <Axis 1>: A wins / B wins / depends on …
- <Axis 2>: …

## Open threads
- <Anything unresolved or worth flagging>
```

### `explorations/YYYY-MM-DD-topic/RECOMMENDATIONS.md`

```markdown
# Recommendations: <topic>

## Recommendation
<The thing to do, stated plainly.>

## Why
<The case, drawing on SYNTHESIS.md. Should be skimmable in under a minute.>

## Caveats
- <What would change this recommendation>
- <Known risks>
```

## Pruning

The structure earns its keep only if it stays light:

- If a file hasn't been touched in a month and isn't load-bearing, delete it.
- `DECISIONS.md` grows steadily — each entry is a paragraph. The file is doing its job when it's still scannable. When it isn't, group by area (e.g. `## Architecture`, `## Tooling`) or move entries that no longer constrain current decisions into `plans/DECISIONS-archive.md`.
- If `LOG.md` exceeds ~200 lines, roll older entries into `plans/LOG-archive.md`.
- Exploration folders are forever — they're the historical record decisions point at.
