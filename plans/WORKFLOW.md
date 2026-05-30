# Project Planning Workflow

A lightweight file structure for keeping Claude Code (and your future self) on task across work blocks. This document lives at `plans/WORKFLOW.md` and is referenced from `CLAUDE.md`.

## Directory layout

```
CLAUDE.md                    # constitution: stack, conventions, invariants
plans/
  WORKFLOW.md                # this document — how the planning files work
  BRIEF.md                   # north star: what & why (1 page, rarely changes; not a roadmap)
  BOARD.md                   # the board — 3 sections: Status (the tree + the one next, rewritten each block) / Milestones (roadmap legend) / Backlog (deferred work + ideas + known issues)
  DECISIONS.md               # settled questions, with refs to explorations (optional leading `Q:` line)
  QUESTIONS.md               # OPEN questions only (settled → DECISIONS; deferred work → BOARD §Backlog)
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
| `BRIEF.md`       | rarely       | problem, success criteria, non-goals, enduring design intent. **Not** the roadmap — milestones live in `BOARD.md` §Milestones. |
| `BOARD.md`       | mixed        | **§Status** — milestone/phase tree, the one `👉 next`, rolled-up open questions & decisions; rewritten (not appended) each block. **§Milestones** — one-line roadmap legend (edited as the path changes). **§Backlog** — deferred work, ideas, known issues as stub + ≤4-line body (edited as items land/graduate). |
| `DECISIONS.md`   | per decision | dated paragraphs with enough context to act on; optional leading `Q:` line for the question resolved; link to exploration RECOMMENDATIONS.md for the deep case |
| `QUESTIONS.md`   | per question | **open questions only** — ⚖️ needs-decision / ❓ genuine-unknown. Settled → DECISIONS.md (with `Q:` line); deferred work → BOARD.md §Backlog. |
| `LOG.md`         | per block    | append-only, dated headers                                                              |
| `features/<slug>.md` | per phase | working plan for a milestone or big feature — scope, phase breakdown, opens, risks. Lifetime tracks the work; delete or supersede when the work closes (LOG.md keeps the trail). |

If you're tempted to add something to CLAUDE.md, ask: *does this constrain how code gets written, forever?* If no, it belongs somewhere in `plans/`.

**File references should be clickable markdown links** — both within `plans/` (e.g. `[`DECISIONS.md`](./DECISIONS.md)`) and out to explorations (e.g. `[`explorations/.../RECOMMENDATIONS.md`](../explorations/...)`). It's much easier to navigate a workflow when every cross-reference is one click away.

## Index vs. home (where detail lives)

Every doc is either an **index** (a scannable list, one line per item) or a **home** (where an item's full detail lives). Pain comes from files trying to be both. The rule: **index lines point; homes hold depth; each item's detail lives in exactly one home, and the index line links to it. Never duplicate — when an item changes status, it MOVES between homes; the old copy is deleted.**

**Smallest home that fits** (the overflow rule):

| Detail size | Home | Shape |
| --- | --- | --- |
| One line | the stub itself | `🗓 headline — ½-line hook` |
| A paragraph (≤~4 lines) | indented body directly under the stub, hard-capped at ~4 lines | headline line, then indented body lines |
| More than a paragraph | a `features/<slug>.md` or an exploration; the stub links out | `🗓 headline — hook → [features/foo.md]` |

**Category-level application:** a category gets its OWN file only when its items are *reliably* detail-heavy. Open questions are → `QUESTIONS.md` stays as their home. Backlog items are usually one-liners → there is NO backlog file; overflow rides as a capped indented body in `BOARD.md` §Backlog and graduates to `features/` when it gets big.

## Status trees

`plans/BOARD.md` §Status is the project's `git status` — where work stands right now,
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
7. **Milestone naming.** A milestone's identity is always a *descriptive slug + a
   one-line description* — never the number alone (a bare "M9" carries no meaning
   when you read it back later). Numbers mark **execution order** and are **assigned
   at pickup**, not reserved in advance: only milestones that are active or completed
   carry a number. **Penciled-in / future milestones carry no number** — refer to them
   by slug (e.g. "Unified sidebar nav") until they're taken on, at which point they
   receive the next number.

### Surfacing status in conversation

Lead with the trees when reporting, not only in `BOARD.md` §Status:

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
decision made          → plans/DECISIONS.md (refs RECOMMENDATIONS.md; prepend a `Q:` line)
                         plans/QUESTIONS.md → delete the now-answered entry
deferred work (no       → plans/BOARD.md §Backlog (stub + ≤4-line body; link out if it has a home)
  decision, just a       plans/QUESTIONS.md → delete the entry (it was never an open question)
  chore/bug/idea)
affects all code       → CLAUDE.md
end of work block      → append plans/LOG.md
                         rewrite plans/BOARD.md §Status + advance the one 👉 next
```

## CLAUDE.md hookup

Add this block near the top of `CLAUDE.md` so Claude Code wires into the workflow:

```markdown
## Project workflow

This project uses the planning structure described in `plans/WORKFLOW.md`. Read it before making non-trivial changes. In short:

- `plans/BOARD.md` — where work stands now: **Status** (the tree + the one next), **Milestones** (roadmap), **Backlog** (deferred work + ideas + known issues). Read first; rewrite §Status each block.
- `plans/BRIEF.md` — what & why (stable design intent; not a living doc).
- `plans/DECISIONS.md` — settled questions (check before proposing architectural changes).
- `plans/QUESTIONS.md` — **open** questions only (settled → DECISIONS; deferred work → BOARD §Backlog).
- `plans/LOG.md` — append a dated entry at the end of each work block.
- `explorations/YYYY-MM-DD-topic/` — investigations that wrap with `SYNTHESIS.md` and `RECOMMENDATIONS.md`.

Two rules: **"add to the backlog"** → the item goes to `plans/BOARD.md` §Backlog, never to QUESTIONS.md. **"next" / "what's next"** → surface status per §"Surfacing status in conversation" (focus tree if active, overview tree at a boundary), then the 👉 next + an offer.
```

## File templates

### `plans/BRIEF.md`

The stable north star — problem, why, enduring design intent. **Not** the roadmap:
milestone descriptions and status live in `BOARD.md` (§Milestones / §Status), not here.
New decisions land in `DECISIONS.md`, not by editing the brief.

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
     The linked RECOMMENDATIONS.md carries the deep case — don't restate it here.
     Optional leading `Q:` line — when the entry resolves a question that was
     tracked in QUESTIONS.md, prepend `Q: <the question>` for traceability. -->

### 2026-05-21 — Use MPS over CPU for inference

Q: MPS or CPU for the training loop and replay-buffer reads?

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

Open questions only — there is no "Answered" graveyard. When a question settles, it MOVES
to `DECISIONS.md` (with a `Q:` line) and the copy here is deleted; deferred work (a chore/bug/idea
with nothing to decide) MOVES to `BOARD.md` §Backlog. This file is itself the dossier home, so
each item is a scannable headline + its detail paragraph.

```markdown
# Open questions

<!-- OPEN questions only — ⚖️ needs-decision / ❓ genuine-unknown. This file is the dossier home:
     each item = a scannable headline + its detail paragraph.
     · Settled → move to DECISIONS.md (prepend a `Q:` line there); delete the copy here.
     · Deferred WORK (a chore/bug/idea with nothing to decide) → BOARD.md §Backlog; delete the copy here.
     File references should be clickable markdown links. -->

- ⚖️ **<needs-decision headline>.** <The detail paragraph — enough context to decide; link the
  exploration / feature where the case lives.>
- ❓ **<genuine-unknown headline>.** <What's unknown and how it gets resolved.>
```

### `plans/BOARD.md`

Three sections. **§Status** is the headline tree (links point to the source of truth, never copy
it; one 👉 next, always last — see "Status trees" above for the full format) and is rewritten each
block. **§Milestones** is a one-line-per-milestone roadmap legend (state lives in §Status; this
answers "what is M5 again?"). **§Backlog** is deferred work / ideas / known issues as stub + ≤4-line
body. The §Status tree and §Milestones legend both name the milestones, but carry different content
(state vs. description) — intentional, not duplication.

```markdown
<!-- The board: where work stands (Status), the path (Milestones), what's deferred (Backlog).
     Status rewritten each block; Milestones/Backlog edited as they change. Best viewed monospace. -->

# <Project> — Board
_Snapshot · <date>_

## Status

├─ ✅ M1 — <name>
├─ 🌱 M2 — <name>
│  ├─ ✅ P1 — <name>
│  └─ 🌱 P2 — <name>     ← here
└─ 📋 M3 — <name>

👉 next  <the one thing>. → [`LOG.md`](./LOG.md)

❓ open → [`QUESTIONS.md`](./QUESTIONS.md)
- ⚖️ <open-question stub>   (only ⚖️/❓ true unknowns; deferred work lives in §Backlog)

📌 recent → [`DECISIONS.md`](./DECISIONS.md)
- <recent-decision stub>

## Milestones

- **M1 — <name>** — <½-line of what it delivers> → [`features/<slug>.md`](./features/<slug>.md)
- **M2 — <name>** — <½-line> → [`features/<slug>.md`](./features/<slug>.md)

## Backlog

<!-- Stub = one line (`🗓 headline — hook`). Add a ≤4-line indented body only when needed.
     Link out (→ features/ or exploration) when the item has a real home. -->

- 🗓 <deferred-work headline> — <½-line hook>
- 🗓 <bigger item> — <hook> → [`features/<slug>.md`](./features/<slug>.md)
```

### `plans/LOG.md`

```markdown
# Work log

<!-- STATUS · snapshot, rewritten each block · full board in BOARD.md -->
🌱 **M2 — <name>** (P1 ✅ · P2 🌱 ← here)
👉 Next: <the one thing>. → [`BOARD.md`](./BOARD.md)
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
