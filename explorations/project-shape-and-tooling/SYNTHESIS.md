# Project shape & tooling — synthesis

> **Status: CONFIRMED 2026-05-20.** See `RECOMMENDATIONS.md` for the locked
> verdicts; this file captures how we got there, what alternatives were
> considered, and what was deferred.

## Methodology

Interactive walkthrough between user and Claude on 2026-05-20. Four
headline questions landed sequentially: package shape, test-app placement,
tooling chain, fixture story. Each question presented 2–4 options with
code/layout previews; user selected one per question. A second-pass
discussion then revisited the package-shape verdict and revised it; the
final verdicts incorporate that revision.

Not researcher-dispatched. Sibling M0 blocks (`prior-projects`,
`swift-ecosystem`, `dev-folder-survey`, `runtime-pipeline-architecture`,
`display-pipeline-architecture`) absorbed the deeper architectural
research; this block resolved operational shape questions that were easier
to answer from existing knowledge than to research.

**Why interactive over researcher.** User wanted to think through
tradeoffs in real time rather than receive a writeup to review. Headline
questions were well-defined enough to enumerate options exhaustively; no
hidden unknowns warranting dedicated research.

## Q1 — Package shape

**Two-pass decision.** First pass picked an umbrella product over six
SwiftPM targets. Second-pass discussion challenged whether multi-target
was warranted at all for a small co-evolving codebase; verdict revised to
single-target.

**Options considered (final):**

| Option | Outcome |
|---|---|
| One package, six granular library products | Rejected (first pass) |
| One package, umbrella product, six targets | Considered, revised away from |
| Multiple packages (one per module) | Rejected (first pass) |
| **One package, one product, one target** (folders inside) | **Final verdict** |

**Why single-target won (second pass).** Three factors converged:

1. **Modules genuinely co-evolve.** Capture, Playback, Detection, Overlay
   are designed against the same `Frame` abstraction and the same
   coordinate conventions. They land together through M1–M3. Forcing
   target boundaries between them creates ceremony without proportional
   benefit.
2. **The "where does `Frame` live?" problem.** Multi-target with `Frame`
   as source-agnostic forces either a backwards dependency (Playback →
   Capture) or an undeclared seventh `IrisCore` target. A single target
   makes `Frame.swift` a root file that everyone references without
   ceremony.
3. **Walkback is cheap.** Extracting a folder into its own target later is
   roughly a half-day per module — move files, declare deps, lift
   `internal` → `public` at the new boundary. Low cost if boundary pain
   surfaces at M2/M3.

**Why the first-pass umbrella verdict fell short.** Umbrella+six-targets
still carried the multi-target overhead (Package.swift complexity,
cross-target dep declarations, the `Frame` ownership problem) for marginal
benefit (some build-time isolation that Swift's incremental compilation
already provides at file level).

**Why granular six-products lost (first pass).** Real benefit for
downstream consumers (link only what you need), but premature — Iris is
designed as a coherent unit, and the user prefers simpler consumer surface
(single `import`). Easy to add granular products later as non-breaking
change.

**Why multi-package lost (first pass).** Six Package.swifts is operational
overhead with no payoff at this scale. Modules co-evolve; cross-package
versioning of shared abstractions adds friction.

**Tuning + Dataset deferred.** User flagged both as M4/M5 work that
shouldn't be scaffolded at M1. Agreed — designing either before seeing
real detector output (Tuning) or real capture flows (Dataset) is
premature.

## Q2 — Test/demo apps

**Options considered:**

| Option | Outcome |
|---|---|
| **`Apps/` folder, real Xcode projects** | **Picked** |
| `.executableTarget` entries in Package.swift | Rejected |
| `Examples/` with sibling SwiftPM packages | Rejected |
| Defer — library + tests only | Rejected |

**Why Xcode projects won.** iOS camera capture testing requires
`NSCameraUsageDescription` in Info.plist; without it, `AVCaptureSession`
refuses to start. SwiftPM executable targets can build iOS apps but
Info.plist permission handling, app icons, and provisioning need awkward
workarounds. A real `.xcodeproj` sidesteps all of it. The cost —
`.xcodeproj` files in git — is manageable with discipline about
scheme/user-state.

**Why executable-targets lost.** Cleaner repo shape (no `.xcodeproj`
clutter), but the Info.plist workaround is friction at the worst possible
moment: M1, when capture is the focus.

**Why Examples-as-packages lost.** Same friction as executable-targets,
plus extra boilerplate (one Package.swift per demo).

**Why "defer" lost.** Tempting at M0 — keep the repo lean. But M1 is
"capture-core", and the iOS demo app is the only way to actually exercise
camera capture on hardware. Better to wire the Apps/ scaffolding into M1
than defer further.

## Q3 — Tooling chain

**Options considered:**

| Option | Outcome |
|---|---|
| **Standard baseline (swift-format + SwiftLint + GHA + DocC + pre-commit)** | **Picked** |
| Minimal (swift-format + GHA only) | Rejected |
| Standard + Codecov + xcbeautify + periphery | Rejected |

**Why standard won.** Iris is a library; downstream consumers expect DocC
and linting consistency. The five-tool baseline is the standard Apple
open-source SwiftPM library shape (matches swift-collections,
swift-algorithms, AsyncAlgorithms). Setting it up once at M1 pays back
across every milestone.

**Pre-commit hook flavor: native git hook, not the Python framework.**
Decided after walking through the friction tradeoff with the user. Python
framework adds polish but requires `brew install pre-commit` per
contributor; native shell script in `.githooks/` plus a one-time
`git config core.hooksPath .githooks` is simpler. For solo dev with
occasional agentic help, native wins.

**Tests do not run in the pre-commit hook.** User raised the concern;
agreed. Pre-commit runs only fast formatter/lint checks (<2s total). Tests
live in CI on push.

**Why minimal lost.** Lower upfront cost (~30 minutes saved), but each
deferred piece costs more to add later than to wire at start. SwiftLint
rules pile up retroactively; DocC catalogs are easier to keep current
than to backfill.

**Why heavy lost.** Codecov, xcbeautify, periphery add signal but also
maintenance burden (PR comment noise, weekly job tuning, false positives
to triage). Worth revisiting once there's a contributor base or a
coverage question worth answering.

**Deferred (revisit when signal warrants):**
- Codecov coverage uploads.
- xcbeautify for prettier CI logs.
- periphery for dead-code detection (wait until public API stabilizes).

## Q4 — Fixture story

**Options considered:**

| Option | Outcome |
|---|---|
| Committed in Tests/, size-capped at ~10MB | Rejected |
| **Git LFS from day one** | **Picked** |
| Synthesize fixtures in code, no binary assets | Rejected |
| External fixture bundle, fetched on demand | Rejected |

**Why LFS won.** Detection fixtures (Core ML models) can be 5–50MB each.
M6 adds custom models and Foundation Models adapters — fixture growth is
likely. LFS adds one `brew install` per contributor and one CI checkout
option; the migration cost of "commit small, switch to LFS later"
requires rewriting git history. Future-proofing is cheap.

**Why size-capped commit lost.** Works today but bets on fixtures staying
small. A single mid-size Core ML model breaks the cap. Discipline-
dependent rather than tool-enforced.

**Why synthesized-in-code lost.** Conflicts with CLAUDE.md's "real
fixtures over mocks" principle. Synthesized frames test geometry but not
the real-world image properties detection backends actually face. Useful
*alongside* real fixtures (e.g., for Overlay geometry tests where image
content doesn't matter), not as a replacement.

**Why external-bundle lost.** Offline-first dev workflow breaks until
first fetch; download server becomes a build dependency. Right for very
large datasets that don't belong in git history at all; wrong for a
library's test fixtures.

## What this block deliberately didn't decide

- **Specific CI matrix dimensions.** macOS-version, Xcode-version, iOS
  Simulator device. Set when wiring `.github/workflows/ci.yml` at M1.
- **swift-format rule choices.** Apple's defaults are the starting point.
  Tweak when a real diff surfaces friction.
- **DocC catalog structure.** Decide when there's actual public API to
  document.
- **Versioning policy.** SemVer from v0.1 vs CalVer vs date-stamped.
  Address at first release.
- **Tuning and Dataset folder shape.** Deferred to M4/M5 by design.
- **README / CONTRIBUTING content.** Drafted at M1 alongside first
  scaffolding.

## BRIEF.md / CLAUDE.md alignment

The "six modules, each a SwiftPM target" framing in CLAUDE.md (and the
implicit framing in BRIEF.md's "High-level components" section) was
updated in the same pass as these verdicts. Both now reflect single-target
with folder organization; CLAUDE.md's `#if os(iOS)` working-norm note was
softened to permit whole-subsystem platform gating (which is how Capture
is iOS-only inside the single Iris target).
