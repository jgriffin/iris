# project-shape-and-tooling — Repo layout, test apps, build tooling

parent: [m0-explorations](.blockmaster/blocks/260520-m0-explorations.md)
created: 2026-05-20 18:00
modified: 2026-05-20 18:00
context: .blockmaster/blocks/260520-project-shape-and-tooling.md
kind: exploration
goal: Lock the overall shape of the Iris repo before M1 code lands — Swift package structure, where iOS + macOS test apps live, and the build/dev tooling chain.

### Context

Fifth and (likely) final M0 child. The two architecture sibling blocks ([runtime-pipeline-architecture](.blockmaster/blocks/260520-runtime-pipeline-architecture.md), [display-pipeline-architecture](.blockmaster/blocks/260520-display-pipeline-architecture.md)) locked the **runtime architecture** — how `Frame`s flow, how isolation works, how display + analysis split, how overlays sync. They deliberately did not address **how the repo is laid out** to deliver any of it.

This block resolves the project-shape questions before M1 starts touching `Sources/`:

1. **Swift package shape** — `BRIEF.md` describes six modules (`IrisCapture`, `IrisPlayback`, `IrisDetection`, `IrisOverlay`, `IrisTuning`, `IrisDataset`). Are they six targets in a single `Package.swift`, or split into multiple packages (core + adapter-repos)? **This is the deferred open question raised by the ecosystem survey** (see `explorations/swift-ecosystem/RECOMMENDATIONS.md`).
2. **Test app placement** — Iris is a library, but ergonomic development needs an iOS app that exercises live capture + detection + overlay, and a macOS app that exercises playback + detection + overlay. Where do they live?
   - In-repo executable targets in the same `Package.swift`?
   - Separate `apps/` directory with their own Xcode projects?
   - Separate repos that depend on Iris locally via SwiftPM path?
   - Each option has consequences for CI, simulator runs, App Store provisioning, and contributor onboarding.
3. **Build tooling** — Swift CLI (`swift build` / `swift test`) vs Xcode-driven; formatter / linter (SwiftFormat? SwiftLint? `swift-format`?); CI surface (GitHub Actions? Xcode Cloud?); DocC; pre-commit hooks. Pick a coherent default chain that scales from "I want to add a test" to "I want a tagged release."
4. **Test infrastructure shape** — `BRIEF.md` and `CLAUDE.md` already say "Tests live alongside their target in `Tests/<Module>Tests/`" and "real fixtures (sample video clips, sample `MLModel`s) in `Tests/<Module>Tests/Fixtures/`." Confirm + flesh out the fixture story (where do `.mov` / `.mlmodelc` fixtures actually come from? Bundled? Generated? Hosted out-of-band?). UI tests for the test apps — in scope or out?

### Scope

**In:**

- Package shape (single-package vs split) — with concrete tradeoffs, not just preferences
- Public vs internal target boundaries — what each module exports, what stays internal
- Test app layout (iOS + macOS) + how they consume the package — local SwiftPM, Xcode workspace, scheme conventions
- Build/dev tooling chain — formatter, linter, CI, DocC, pre-commit
- Test infrastructure — fixture management, where binaries live (in-repo? git-LFS? Out-of-band?)
- Top-level `.gitignore` policy + what's already covered
- File-naming + folder conventions inside `Sources/<Module>/`
- Versioning / tagging strategy at a high level (semver, release cadence — just enough to not paint into a corner)

**Out:**

- Specific test cases (those land in the module-level blocks)
- Concrete CI workflow YAML (decide the system; the workflow file is M1+ work)
- App Store provisioning details (test apps are developer-only)
- Documentation content (DocC tooling choice is in; what docs to write is out)
- M1+ module implementation (this block is repo-shape only)

### Open questions this resolves

- **Package layout** — single `Package.swift` with N targets vs core + adapter-repos. Deferred from the ecosystem survey; this is the natural place to settle it.
- **Test app shape** — in-repo executable targets vs companion Xcode projects vs separate repos.
- **Default tooling chain** — formatter, linter, CI, DocC, pre-commit. Picked, not surveyed.
- **Fixture story** — bundled in `Tests/<Module>Tests/Fixtures/`, generated, or fetched on demand?

### Inputs

- `BRIEF.md` — modules, conventions, working norms
- `CLAUDE.md` — repo working norms (test placement, fixtures, gitignore policy)
- `explorations/swift-ecosystem/RECOMMENDATIONS.md` — the deferred package-layout question is documented here
- `explorations/swift-ecosystem/apple-avcam.md` — Apple's reference for a sample-app-shaped project
- `explorations/swift-ecosystem/nextlevel.md`, `mijick-camera.md`, `kadr.md` — for SwiftPM library + sample-app patterns
- `explorations/prior-projects/yolo-ios-app.md` — strongest in-house signal on public Swift package craft
- `explorations/prior-projects/ios-videoCapture.md` — modular SPM mirror pattern
- `explorations/prior-projects/sportvision.md` — Swift 6 + iOS/macOS dual-target reference (relevant for the test-app split)

### Approach

**Open question — pending user input on methodology.** This block is opened scoped but **no researcher dispatched yet**. The two sibling blocks used a single focused researcher returning SYNTHESIS + RECOMMENDATIONS — that pattern is available, but project-shape is more opinion-driven and less doc-citation-driven, so the user may prefer to walk through the decisions interactively first.

Likely shape either way: deliverables under `explorations/project-shape-and-tooling/` (`SYNTHESIS.md` + `RECOMMENDATIONS.md`), in the same convention as the prior two architecture blocks.

### Pick-up-here

Block opened with concrete scope. **No researcher dispatched** — per user direction ("we'll do that next"), awaiting user input on whether to dispatch a researcher or work through the decisions interactively. Headline questions to land: (1) single-package vs split, (2) test-app placement, (3) tooling chain, (4) fixture story. After this closes, M0 has all five children closed and is ready to close — optionally after a BRIEF.md refresh pass folding in all accumulated verdicts.

### Progress

- 2026-05-20 18:00 — created and opened with scope; researcher dispatch deferred per user direction.
