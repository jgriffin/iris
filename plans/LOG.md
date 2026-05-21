# Work log

<!-- Append-only. Newest at bottom. -->

## 2026-05-21
- Did: migrated to the `plans/` workflow described in [`WORKFLOW.md`](./WORKFLOW.md). Moved `BRIEF.md` from repo root into `plans/`. Pulled "Open design questions" and "Milestone path" out of [`../CLAUDE.md`](../CLAUDE.md) — questions now live in [`QUESTIONS.md`](./QUESTIONS.md), milestones in [`BRIEF.md`](./BRIEF.md). Created [`DECISIONS.md`](./DECISIONS.md) capturing the M0 exploration verdicts.
- Did: deleted `explorations/RECOMMENDATIONS-PRIOR-ART.md` — judged an anti-pattern after auditing the rollup against the per-arc files. Updated the four references that pointed at it.
- Did: enriched [`DECISIONS.md`](./DECISIONS.md) entries from one-liners to paragraph-per-decision with clickable links. Updated [`WORKFLOW.md`](./WORKFLOW.md)'s `DECISIONS.md` template and pruning guidance to match: entries should give enough context to act without opening the reference, blank-line-separated, file refs as markdown links.
- Note: existing exploration folders (`prior-projects/`, `swift-ecosystem/`, `project-shape-and-tooling/`, `runtime-pipeline-architecture/`, `display-pipeline-architecture/`) don't follow the `YYYY-MM-DD-topic/` naming from [`WORKFLOW.md`](./WORKFLOW.md). Leaving them as-is to preserve links; the dated convention applies to new explorations going forward.
- Next: M1 (`IrisCapture`) plans lock once the two M1-blocking opens in [`QUESTIONS.md`](./QUESTIONS.md) are settled — package-layout fork and the `Detector` stateful-conformer shape. Sidecar format can wait until M5.
