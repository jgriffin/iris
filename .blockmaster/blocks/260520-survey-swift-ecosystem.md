# survey-swift-ecosystem — Survey the wider Swift package ecosystem for Iris-relevant prior art

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 14:00
modified: 2026-05-20 (opened with concrete two-phase scope)
context: .blockmaster/blocks/260520-survey-swift-ecosystem.md
kind: research
goal: Find, shortlist, and deep-read external Swift packages that already do pieces of what Iris will do — so Iris can stand on existing work where it's good and consciously diverge where it isn't.

### Context

`review-prior-projects` ✅ deep-read 5 in-house projects in `~/dev/` and produced `explorations/prior-projects/{SYNTHESIS,RECOMMENDATIONS}.md`. That covered our *own* prior art. This block covers the *external* prior art — open-source Swift packages on swiftpackageindex.com, GitHub, and the broader ecosystem that might give Iris ready-made building blocks for capture, playback, detection, overlay, tuning, or dataset capture.

The point isn't NIH paranoia and it isn't "depend on everything." It's: before we commit to writing `IrisCapture` from scratch, know whether (e.g.) a polished SwiftUI-camera package already nails the bridging story; before designing `Detector`'s protocol shape, know whether a well-maintained Vision-wrapper package exists with a shape worth borrowing or worth distinguishing from.

Outcome of *this* block (rolled up from its children) is a small set of go/no-go recommendations per area: "use it," "borrow from it," "study it then diverge," or "ignore." Augments the existing `RECOMMENDATIONS.md` rather than replacing it.

### Approach

Two-phase, nested. Same survey→review rhythm as the prior-art arc.

1. [search-swift-packages](.blockmaster/blocks/260520-search-swift-packages.md) — scan swiftpackageindex.com tags, GitHub topics, awesome-* lists, and the recent web for candidates across all six Iris module areas. Narrow to a shortlist with `path · last activity · stars · platforms · primary signal · one-line relevance` per entry. Land the shortlist in `explorations/swift-ecosystem/SHORTLIST.md`.
2. [deep-dive-swift-packages](.blockmaster/blocks/260520-deep-dive-swift-packages.md) — for each shortlisted package, the same four-lens deep-read used in `review-prior-projects` (capture entrypoint / Frame plumbing / detection async / overlay coords) plus a public-API-shape lens (since these are packages, not apps). Per-package notes under `explorations/swift-ecosystem/<package-slug>.md`; synthesis lands in `explorations/swift-ecosystem/RECOMMENDATIONS.md` (per-arc) with cross-cutting rollup at `explorations/RECOMMENDATIONS-PRIOR-ART.md`.

### Children

- [search-swift-packages](.blockmaster/blocks/260520-search-swift-packages.md) — 🟡 in flight; produces shortlist
- [deep-dive-swift-packages](.blockmaster/blocks/260520-deep-dive-swift-packages.md) — 📋 queued; scope set by child 1's shortlist

### Output

- `explorations/swift-ecosystem/SHORTLIST.md` (from child 1)
- `explorations/swift-ecosystem/<package-slug>.md` per shortlisted package (from child 2)
- Recommendations: per-arc `explorations/swift-ecosystem/RECOMMENDATIONS.md` + cross-cutting rollup `explorations/RECOMMENDATIONS-PRIOR-ART.md`; both feed BRIEF.md updates as needed

### Pick-up-here

`search-swift-packages` 🟡 is the active leaf. When it closes with a shortlist, open `deep-dive-swift-packages` against that shortlist (same opening pattern as `review-prior-projects` opening after `survey-dev-folder` closed). Close this parent when both children close.

### Progress

- 2026-05-20 14:00 — created and opened; two child research blocks set up (search 🟡, deep-dive 📋)
- 2026-05-20 — `search-swift-packages` ✅ closed with SHORTLIST.md (5 Tier-1 packages after user prune); `deep-dive-swift-packages` opened with concrete scope
- 2026-05-20 — `deep-dive-swift-packages` ✅ closed with 5 per-package notes + `explorations/swift-ecosystem/RECOMMENDATIONS.md` + cross-cutting rollup at `explorations/RECOMMENDATIONS-PRIOR-ART.md`. Parent closed.

### Outcome

Both children closed:

- [search-swift-packages](.blockmaster/blocks/260520-search-swift-packages.md) ✅ — [`SHORTLIST.md`](../../explorations/swift-ecosystem/SHORTLIST.md) with 5 Tier-1 packages, Apple-framework verdicts, 8 headline findings (three Iris modules have zero SPM competition; Apple has eaten the Detection-wrapper space; AsyncStream-per-frame is consensus-but-unpackaged; etc.).
- [deep-dive-swift-packages](.blockmaster/blocks/260520-deep-dive-swift-packages.md) ✅ — 5 per-package notes under `explorations/swift-ecosystem/`. Verdicts: AVCam **Borrow**, NextLevel **Study-then-diverge**, MijickCamera **Study-then-diverge**, Kadr **Borrow structurally**, PrivateFoundationModels **Study-then-diverge**. Findings folded into the project recommendations doc.

**The combined arc (`survey-dev-folder` ✅ → `review-prior-projects` ✅ → `survey-swift-ecosystem` ✅) leaves M0 with:**

- Verdicts on 4 of the original 6 BRIEF.md M1 open questions (Q1 async, Q2 `@CaptureActor`, Q4 hot-swap, Q5 macOS parity) from the in-house read
- Additional resolutions on Q6 (Foundation Models) and three of the M1-from-the-prior-art "still open" items (Source-protocol unification, `DetectorCache` ownership, cancellation policy) from the external read
- A new fork on package layout (single-package multi-target vs core + adapter-repos) to decide before M1 plans lock
- One genuinely open question: Q3 sidecar format (COCO vs YOLO vs Create ML JSON) — decide on domain merits
- 15+ concrete patterns to lift, ~10 anti-patterns to forbid, ~12 scope additions for M1 capture

Ready for M0 close, optionally after a `BRIEF.md` refresh pass folding the resolutions in.
