import Foundation
import Iris
import Observation
import os

// MARK: - Test deferral note
//
// Like `RecentVideos` / `ModelSelection`, this file lives under `Apps/Shared/`
// (consumed by both demo Xcode targets via `Apps/project.yml`) and is **not**
// reachable from any SwiftPM test target — the library's `Tests/IrisTests/`
// can only see code under `Sources/Iris/`. So the unit tests the feature doc
// asks for (visibility transitions, clear-keeps-opinions, idempotent sightings,
// clamp semantics, Codable round-trip incl. `{}` entries) have no home today
// without standing up a new `IrisDemoSupport` SwiftPM target — the same trade
// `RecentVideos` rejected. Behavior is observable through the panel UI (P3) and
// the static preview gallery (P4). Revisit by extracting a demo-support target
// if a regression here ever bites twice.

/// The single per-detector per-class **store** that *is* the whole tuning
/// panel's per-class state (M12). One map, keyed by detector catalog id, holds
/// both **accumulation** (which labels a detector has been seen emitting) and
/// the **user's opinions** about each (show / hide / per-label floor):
///
/// ```
/// detector id → label → LabelState { visibility?, floor? }
/// ```
///
/// **Key membership = accumulation; values = opinions.** A label enters a
/// detector's map the first time that detector emits it (``recordSightings``).
/// An empty ``LabelState`` (`{}`) is meaningful: *"seen, no opinion"* — the
/// tri-state **Auto** default. A key can also be created by opining on a
/// not-yet-seen label (e.g. pinning from the full-roster expander), so
/// membership is really "seen **OR** opined-on" — either way the label belongs
/// in the working list.
///
/// **Detector-keyed by construction.** A YOLO `person` and another model's
/// `person` never share history or opinions; switching the active detector
/// switches the whole per-class view.
///
/// **Start clean (M12·P1 decision, 2026-06-04).** This store does NOT read the
/// legacy global `ModelSelection` per-class keys (`perLabelMinConfidence` /
/// `hiddenLabels` / `pinnedLabels`); it starts empty. There's no real corpus
/// yet, so folding the unattributed global maps into a best-guess detector
/// slice would invent attribution that isn't there.
///
/// Persistence mirrors `ModelSelection` / `RecentVideos`: a `UserDefaults`-backed
/// `@Observable` that loads in `init` and writes on every mutation. The encoded
/// value is JSON over the `Codable` map, under a single `.v1` key; a stored
/// `version` field rides inside the payload for future migration.
///
/// Concurrency: `@Observable` + `@MainActor`. All mutations happen from the UI
/// thread; `UserDefaults` is the single backing store and this is its single
/// writer.
/// The user-facing tri-state for a class label in the per-class panel — the
/// eye-tap affordance order is Hide → Auto → Show → Hide.
///
/// - ``hide``: never drawn, even when detected.
/// - ``auto``: drawn when present; the DEFAULT for a newly-seen label.
/// - ``show``: pinned — always listed in the per-class UI + drawn when present,
///   even before it first appears.
///
/// This is the panel's tri-state; ``DetectorLabelStore/Visibility`` is the
/// stored two-case form (Auto = `nil`). Lifted out of `ModelSelection` (M12·P1)
/// — `ModelSelection.LabelVisibility` remains as a typealias bridge for P1.
enum LabelVisibility: Sendable, CaseIterable {
    case hide, auto, show
}

@MainActor
@Observable
final class DetectorLabelStore {
    /// Storage key. `.v1` lets future schema bumps migrate cleanly.
    static let defaultKey = "iris.detectorLabels.v1"

    /// The drawing/listing state of a single class label, *for one detector*.
    ///
    /// - ``hide``: never drawn, even when detected.
    /// - ``auto``: drawn when present; the DEFAULT for a newly-seen label
    ///   (encoded as `visibility == nil`, NOT a stored `auto` case — so a `{}`
    ///   entry round-trips as Auto).
    /// - ``show``: pinned — always listed in the per-class UI + drawn when
    ///   present, even before it first appears.
    enum Visibility: String, Sendable, CaseIterable, Codable {
        case hide, show
    }

    /// One label's per-detector state. Both fields optional: a `{}` value means
    /// "seen, no opinion" (Auto, global floor). Matches the schema in
    /// `plans/features/label-accumulation.md`.
    ///
    /// `floor` is `Double` to match `ModelSelection.perLabelMinConfidence`'s
    /// numeric type and the `Double` slider bindings in `PerClassRow` — no
    /// Float/Double conversion churn at the call sites.
    struct LabelState: Codable, Equatable, Sendable {
        /// `nil` = Auto (the tri-state default). Only `hide` / `show` are stored.
        var visibility: Visibility?
        /// `nil` = fall back to the global floor. A stored per-label floor.
        var floor: Double?

        /// `true` when this entry carries no explicit opinion — a bare sighting
        /// (`{}`). These are the entries ``clearSightings(for:)`` drops.
        var isDefault: Bool { visibility == nil && floor == nil }
    }

    /// The whole persisted payload: a schema `version` + the keyed map. Kept as
    /// the Codable shape so the `version` field is part of the JSON, exactly as
    /// the approved schema shows.
    private struct Payload: Codable {
        var version: Int
        var detectors: [String: [String: LabelState]]
    }

    /// Current schema version, embedded in the persisted JSON.
    static let schemaVersion = 1

    /// detector catalog id → label → LabelState. Observed by the panel; mutating
    /// it re-runs each consuming overlay/view. Persisted on every change.
    private(set) var detectors: [String: [String: LabelState]] = [:]

    private let defaults: UserDefaults
    private let key: String

    /// - Parameters:
    ///   - defaults: `UserDefaults` instance to read/write. Override for tests
    ///     (`UserDefaults(suiteName:)`) so the test doesn't clobber real state.
    ///   - key: storage key. Override for tests or future schema bumps.
    init(defaults: UserDefaults = .standard, key: String = DetectorLabelStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        self.detectors = Self.load(from: defaults, key: key)
    }

    // MARK: - Visibility / floor accessors (absorbed from ModelSelection)

    /// The current tri-state for `label` under `detectorID`. A missing entry, or
    /// an entry with `visibility == nil`, both read as ``LabelVisibility/auto``.
    func visibility(of label: String, for detectorID: String) -> LabelVisibility {
        switch detectors[detectorID]?[label]?.visibility {
        case .hide: return .hide
        case .show: return .show
        case nil: return .auto
        }
    }

    /// Set a label's tri-state under `detectorID`. `auto` clears the stored
    /// visibility (back to `nil`) but leaves the entry — and any floor — in
    /// place; `hide` / `show` store the corresponding case (mutually exclusive
    /// by construction, since it's a single optional).
    func setVisibility(_ visibility: LabelVisibility, of label: String, for detectorID: String) {
        let stored: Visibility?
        switch visibility {
        case .hide: stored = .hide
        case .auto: stored = nil
        case .show: stored = .show
        }
        mutate(detectorID, label) { $0.visibility = stored }
    }

    /// Cycle a label Hide → Auto → Show → Hide (the eye-tap affordance order),
    /// preserving the prior `ModelSelection.cycleVisibility` order exactly.
    func cycleVisibility(of label: String, for detectorID: String) {
        switch visibility(of: label, for: detectorID) {
        case .hide: setVisibility(.auto, of: label, for: detectorID)
        case .auto: setVisibility(.show, of: label, for: detectorID)
        case .show: setVisibility(.hide, of: label, for: detectorID)
        }
    }

    /// The per-label floor for `label` under `detectorID`, or `nil` if none set.
    func floor(of label: String, for detectorID: String) -> Double? {
        detectors[detectorID]?[label]?.floor
    }

    /// Set a per-label confidence floor under `detectorID`, clamped to
    /// `≥ globalFloor`. A per-class floor can be stricter than the global one,
    /// never looser — the global floor is a hard render-side floor everything
    /// sits above (preserves `ModelSelection.setPerLabelFloor`'s clamp).
    func setPerLabelFloor(_ value: Double, of label: String, for detectorID: String, globalFloor: Double) {
        mutate(detectorID, label) { $0.floor = max(value, globalFloor) }
    }

    /// Clear a label's per-label floor under `detectorID` (back to the global
    /// floor). Leaves the entry (and its visibility) in place.
    func clearPerLabelFloor(of label: String, for detectorID: String) {
        mutate(detectorID, label) { $0.floor = nil }
    }

    // MARK: - Accumulation

    /// Record that `detectorID` emitted each of `labels` — an idempotent
    /// key-insert into its map. Empty-string labels (class-agnostic detectors)
    /// are filtered out, as today. **Write-on-change only**: if every label is
    /// already a key, nothing is persisted (the membership check is the dedupe),
    /// so the hot detection loop only touches the store on a genuinely new label.
    func recordSightings(_ labels: some Sequence<String>, for detectorID: String) {
        var slice = detectors[detectorID] ?? [:]
        var changed = false
        for label in labels where !label.isEmpty {
            if slice[label] == nil {
                slice[label] = LabelState()
                changed = true
            }
        }
        guard changed else { return }
        detectors[detectorID] = slice
        persist()
    }

    /// Forget a detector's *sightings only*: drop entries whose `LabelState` is
    /// empty/default (no explicit visibility, no floor); **keep** entries that
    /// carry any explicit opinion. You get a fresh "what's been seen" list
    /// without losing your pins / hides / floors. Write-on-change only.
    func clearSightings(for detectorID: String) {
        guard let slice = detectors[detectorID] else { return }
        let kept = slice.filter { !$0.value.isDefault }
        guard kept.count != slice.count else { return }
        if kept.isEmpty {
            detectors[detectorID] = nil
        } else {
            detectors[detectorID] = kept
        }
        persist()
    }

    /// All labels known for `detectorID` — seen or opined-on. The panel's stable
    /// working list (no frame-to-frame flicker).
    func labels(for detectorID: String) -> Set<String> {
        Set(detectors[detectorID]?.keys ?? [:].keys)
    }

    /// `true` when `detectorID` has any entry carrying an explicit opinion —
    /// gates the panel's group-reset affordance (P3).
    func hasAnyOpinion(for detectorID: String) -> Bool {
        detectors[detectorID]?.values.contains { !$0.isDefault } ?? false
    }

    /// `true` when `detectorID` has any **bare sighting** (a default/`{}` entry)
    /// that ``clearSightings(for:)`` would drop — gates the panel's "Clear seen
    /// labels" affordance (P3). False when every entry carries an explicit
    /// opinion (nothing to forget) or the detector has no entries at all.
    func hasClearableSightings(for detectorID: String) -> Bool {
        detectors[detectorID]?.values.contains { $0.isDefault } ?? false
    }

    /// Drop every explicit opinion for `detectorID` (visibility + floor) while
    /// keeping the labels as bare sightings — the "Reset all" affordance.
    func clearOpinions(for detectorID: String) {
        guard var slice = detectors[detectorID], slice.values.contains(where: { !$0.isDefault })
        else { return }
        for label in slice.keys {
            slice[label] = LabelState()
        }
        detectors[detectorID] = slice
        persist()
    }

    // MARK: - Render filter assembly

    /// The library render-time ``OverlayFilter`` for `detectorID`, assembled from
    /// that detector's slice. Preserves `ModelSelection.overlayFilter`'s exact
    /// semantics, per-detector-keyed:
    ///
    /// - **Hidden labels** (`visibility == .hide`) are excluded from drawing.
    /// - **Per-label floors are clamped to `≥ globalFloor`** (belt-and-suspenders
    ///   with the UI clamp) so a stale stored override below a raised global
    ///   floor can never *loosen* below it.
    /// - **Pinned ("show") doesn't enter the filter** — Show == Auto for drawing
    ///   (both draw when present); only `hiddenLabels` suppresses. Pinning is
    ///   purely app-side listing state.
    func overlayFilter(for detectorID: String, globalFloor: Double) -> OverlayFilter {
        let slice = detectors[detectorID] ?? [:]
        var perLabel: [String: Float] = [:]
        var hidden: Set<String> = []
        for (label, state) in slice {
            if state.visibility == .hide { hidden.insert(label) }
            if let floor = state.floor {
                perLabel[label] = Float(max(floor, globalFloor))
            }
        }
        return OverlayFilter(
            globalMinConfidence: Float(globalFloor),
            perLabelMinConfidence: perLabel,
            hiddenLabels: hidden
        )
    }

    // MARK: - Mutation + persistence

    /// Read-modify-write a single label's `LabelState` under `detectorID`,
    /// creating the entry if absent, and persist if it actually changed.
    private func mutate(_ detectorID: String, _ label: String, _ body: (inout LabelState) -> Void) {
        var slice = detectors[detectorID] ?? [:]
        var state = slice[label] ?? LabelState()
        let before = state
        body(&state)
        guard state != before || slice[label] == nil else { return }
        slice[label] = state
        detectors[detectorID] = slice
        persist()
    }

    private func persist() {
        let payload = Payload(version: Self.schemaVersion, detectors: detectors)
        do {
            let blob = try JSONEncoder().encode(payload)
            defaults.set(blob, forKey: key)
        } catch {
            Logger.labels.error(
                "persist: encode failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func load(
        from defaults: UserDefaults, key: String
    ) -> [String: [String: LabelState]] {
        guard let blob = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode(Payload.self, from: blob).detectors
        } catch {
            Logger.labels.error(
                "load: decode failed (resetting store): \(String(describing: error), privacy: .public)"
            )
            return [:]
        }
    }
}

extension Logger {
    fileprivate static let labels = Logger(subsystem: "iris.demo", category: "detector-labels")
}
