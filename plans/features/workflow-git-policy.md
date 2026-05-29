# Workflow git policy — branching, auto-commit, merge cadence

<!-- Captured design, not yet applied. Lifetime ~ until adopted into WORKFLOW.md;
     then this doc can be superseded (LOG keeps the trail). Status vocab per WORKFLOW.md. -->
_Captured · 2026-05-29_ · **📋 defined, deferred — not yet applied**

## Why this exists

The assistant defaulted to "commit only when the user asks." That's **not** from
any of the user's config — it's a **built-in Claude Code harness default** (the
Bash tool's `# Git` guidance: *"Commit or push only when the user asks. If on the
default branch, branch first."*). It's reinforced by the user-authored global hook
[`~/.claude/hooks/intent-vs-action-guard.sh`](file:///Users/griff/.claude/hooks/intent-vs-action-guard.sh)
(the "[Pre-turn gate]" reminder), which lists "commit it" as a directive verb and
says *"DO NOT call state-modifying Bash until the user gives an explicit directive
in THIS turn."* The two stacked → the assistant waited to be told.

The user wants the **opposite**: proactive committing (commits are reversible /
amendable), milestone + phase branches so phase boundaries are noticeable and
merges are reversible, and the human **out of the loop** in most cases. And the
policy must live in **one portable home** — `plans/WORKFLOW.md`, the lead doc this
process is meant to be reused from across projects — not spread around.

## The policy to adopt

- **Milestone branch.** `mN-<slug>` (e.g. `m8-image`) off `main`.
- **Phase sub-branches.** `mN-pX-<slug>` off the milestone branch. A
  throwaway/experimental phase can stay a scratch branch; a real phase merges up.
- **Auto-commit at a verified phase/block end.** Phase done + checks green
  (tests + lint) → commit on the current branch **without being asked**; the commit
  *finalizes directed work*, it is not a separate action needing its own say-so.
  This **overrides the harness default**. Per-phase commits + non-ff merges keep
  history inspectable and reversible — the reason the human can stay out of the loop.
- **Merge is readiness-gated, not human-gated.** Merge a phase sub-branch up to the
  milestone branch once it's green and **nothing is owed** (no 👀 needs-verification,
  no skipped/failing checks). If verification is owed, hold + surface it (👀).
  Back-to-back phases: commit each, merge up as each verifies, keep going.
- **`main` is the one deliberate gate.** Milestone → `main` merges, and any `push`,
  are confirmed first (the outward, shared line). A standing "take it all the way" /
  "do all the phases" pre-authorizes end-to-end through the milestone merge for that run.

## Where each piece goes (single home + pointers — no spread)

- **`plans/WORKFLOW.md`** → the canonical home: a new `## Branching & commits`
  section (full draft below), a one-line add to the **Lifecycle** block
  (`end of work block → … + commit the block on its branch`), and a pointer
  bullet + third rule in the **"CLAUDE.md hookup"** template so adopting projects
  inherit it.
- **Project `CLAUDE.md`** → a **single pointer line** in its "Project workflow"
  section: the git/commit policy lives in `WORKFLOW.md §Branching & commits` and
  **overrides the harness "commit only when asked" default**. DRY — pointer, not copy.
  This is the always-in-context anchor that makes the override fire.
- **`intent-vs-action-guard.sh`** → **untouched.** It's global/non-portable and its
  real job (gate *questions*) is still wanted. The carve-out — "committing finalizes
  directed work, not a separate action" — is stated in WORKFLOW.md. Revisit the hook
  only if commit-hesitation friction recurs in practice.

## Draft `WORKFLOW.md` section (ready to paste)

```markdown
## Branching & commits

The git rhythm rides the milestone/phase/block structure above.

- **Milestone branch.** Each milestone gets a branch `mN-<slug>` (e.g. `m8-image`)
  off `main`.
- **Phase sub-branches.** Each phase gets `mN-pX-<slug>` off the milestone branch.
  A throwaway/experimental phase can stay a scratch branch; a real phase merges up.
- **Auto-commit at a verified phase/block end.** When a phase is done and its
  checks are green (tests + lint), commit it on the current branch **without
  waiting to be asked** — the commit *finalizes the directed work*, it is not a
  separate action needing its own say-so. (This overrides the harness "commit only
  when the user asks" default.) Per-phase commits + non-ff merges are what keep the
  history inspectable and reversible — the reason a human can stay out of the loop.
- **Merge is readiness-gated, not human-gated.** Merge a phase sub-branch up to the
  milestone branch once the phase is green and **nothing is owed** — no 👀
  needs-verification item, no skipped/failing checks. If verification is owed, hold
  the merge and surface it (👀). Running phases back-to-back: commit each, merge up
  as each verifies, keep going.
- **`main` is the one deliberate gate.** Merging a milestone branch → `main`, and
  any `push`, are confirmed first — `main` is the outward, shared line. A standing
  "take it all the way" / "do all the phases" authorizes end-to-end through the
  milestone merge for that run.
```

## One-time cleanup when adopted

- **Rename the current branch** `m8-p1-detection-runner` → `m8-image`. It already
  holds P1+P2+P3 — a de-facto milestone branch with a stale per-phase name. Going
  forward cut `m8-pX-<slug>` sub-branches off it. Not worth retroactively
  sub-branching the already-landed P1–P3 commits.

## Open fork

- **`main`-merge autonomy.** Drafted as *confirm-first, but a standing "do all the
  phases" pre-authorizes through the milestone merge.* Alternative: milestone →
  `main` merges fully autonomous too. **Undecided** — settle when adopting.

## Done when

WORKFLOW.md carries the section + hookup-template update + Lifecycle line; the
project CLAUDE.md carries the one pointer line; the branch is renamed; the open
fork is resolved into the section text. Then this doc is superseded.
