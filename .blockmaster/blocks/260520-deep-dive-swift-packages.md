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

### Scope (from `SHORTLIST.md`, user-approved)

Five packages, one per deep-read agent, all parallel:

1. **Apple AVCam (SwiftUI sample)** — [developer.apple.com/documentation/avfoundation/avcam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) · Apple sample · iOS 18+ · *Priority: the `CaptureService` actor architecture — this is the canonical reference everyone implicitly converges on, including the Swift Forums Dec-2025 consensus thread.*
2. **NextLevel** — [github.com/NextLevel/NextLevel](https://github.com/NextLevel/NextLevel) · 2,306★ · iOS 16+ Swift 6 · *Priority: Swift 6 migration scars in the CHANGELOG, per-frame `imageBuffer` hook, AsyncStream session events, Sendable boundaries on `CMSampleBuffer`.*
3. **MijickCamera** — [github.com/Mijick/Camera](https://github.com/Mijick/Camera) · 622★ · iOS 14+ · *Priority: SwiftUI public-API shape — what's the preview view, what's hidden, where's the boundary Iris should keep (bottom half) vs drop (top half / built-in UI shell).*
4. **Kadr** — [github.com/SteliyanH/kadr](https://github.com/SteliyanH/kadr) · 41★ · iOS 16+/macOS 13+/tvOS/visionOS Swift 6.0 · *Priority: architectural template. Multi-target SPM with `kadr-ui` / `kadr-captions` / `kadr-photos` companion packages — 1:1 mirror of Iris's shape, different domain (video composition). Read README + ARCHITECTURE + v0.10-v0.12 changelog for real Swift 6 strict-concurrency migration pain.*
5. **PrivateFoundationModels** — [github.com/john-rocky/PrivateFoundationModels](https://github.com/john-rocky/PrivateFoundationModels) · 4★ · iOS 18+ · *Priority: the polymorphic backend pattern (iOS 26 → FM native, older OSes → CoreML/MLX). Directly informs M1 Q6 (Foundation Models as Detector backend vs separate Captioner). Small codebase — focus on API shape and backend dispatch.*

### Pick-up-here

Dispatch five parallel deep-read agents. Each writes `explorations/swift-ecosystem/<slug>.md` using the same five-lens structure as `explorations/prior-projects/<slug>.md` reads (capture entry / Frame plumbing / detection async / overlay coords) plus a **public-API-shape lens** (since these are packages, not apps) and a **Go/No-Go verdict** at the end (use / borrow / study-then-diverge / ignore). Each note also includes opinions on Iris's remaining-open M1 questions (Q3 sidecar format, Q6 Foundation Models scope, Source-protocol unification, cache ownership, cancellation policy).

When all 5 land, append a "Recommendations from external packages" section to `explorations/prior-projects/RECOMMENDATIONS.md` rolling up the go/no-go calls, new patterns, and any updates to the "Still open" list. Don't start a parallel recommendations doc.

### Progress

- 2026-05-20 14:00 — created and queued
- 2026-05-20 — opened with 5-package user-approved scope; deep-read agents dispatched in parallel
