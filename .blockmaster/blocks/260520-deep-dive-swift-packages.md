# deep-dive-swift-packages — Deep-read shortlisted external Swift packages

parent: [survey-swift-ecosystem](.blockmaster/blocks/260520-survey-swift-ecosystem.md)
created: 2026-05-20 14:00
modified: 2026-05-20 (created; queued until `search-swift-packages` closes)
context: .blockmaster/blocks/260520-deep-dive-swift-packages.md
kind: research
goal: For each package shortlisted by `search-swift-packages`, produce a focused read covering Iris-relevant patterns, divergence points, and a go/no-go recommendation.

### Context

Consumes the shortlist produced by [search-swift-packages](.blockmaster/blocks/260520-search-swift-packages.md). Stays 📋 until that block closes — its scope depends on the shortlist contents.

### Approach (sketch — refine at open)

Same four lenses as `review-prior-projects` worked well; reuse them, plus add a fifth that matters for *packages* (vs apps):

1. Capture entrypoint shape.
2. Frame plumbing.
3. Detection / inference async pattern.
4. Overlay coordinate-space handling.
5. **Public API shape** — what's `public`, what's hidden behind `@_spi`, version-stability story, what consumers actually have to import to use it. This dimension was missing from the prior-art reads since those were apps; for external packages it's load-bearing because Iris might *depend on* one, not just borrow from it.

Per package: a `path · stars · last activity · platforms` header, the five lenses, then a **Go/No-Go recommendation** in one of four shapes:

- **Use it** — depend on it directly from Iris.
- **Borrow from it** — lift a specific pattern/file into Iris with attribution.
- **Study then diverge** — read for understanding; Iris will do this part differently and we can explain why.
- **Ignore** — surfaced in shortlist but on deep-read isn't relevant to Iris.

### Output

- Per-package notes under `explorations/swift-ecosystem/<package-slug>.md` (same shape as `explorations/prior-projects/<project-slug>.md`).
- **Extension to** `explorations/prior-projects/RECOMMENDATIONS.md` — add a "Recommendations from external packages" section folding in the go/no-go decisions, the new patterns worth lifting, and any updates to the "Still open" list. Don't start a parallel recommendations doc; one is enough.
- Outcome in this block file: the go/no-go table + a one-line BRIEF.md impact note.

### Pick-up-here

Awaiting `search-swift-packages` close. When the shortlist lands, open this block with concrete scope: list the packages from the shortlist, set per-package priority lens, dispatch parallel deep-read agents (one per package, same pattern as `review-prior-projects`).

### Progress

- 2026-05-20 14:00 — created and queued
