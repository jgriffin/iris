import CoreMedia
import Foundation
import SwiftUI

// MARK: - Scrubber

/// SwiftUI playback control: track slider + play/pause + frame-step
/// buttons, bound to a [`ScrubberModel`](./ScrubberModel.swift).
///
/// **Generic over the model type, not existential.** Matches
/// [`DetectionLayer<Converter: NormalizedGeometryConverting>`](../Overlay/DetectionLayer.swift)
/// — the protocol abstraction stays a compile-time constraint so SwiftUI's
/// dependency tracking sees the concrete `@Observable` properties. An
/// existential `any ScrubberModel` would erase the observation seams.
///
/// **Composition.** `Scrubber` does not own the model — callers construct
/// a [`PlaybackController`](./PlaybackController.swift) (or a mock for
/// previews) and pass it in. The same controller can simultaneously feed
/// `DetectionLayer.displayTimeSource: { [model] in model.currentTime }`
/// so overlay lookups stay registered with the scrub position. That
/// wiring lives in the demo app (M3 Phase 5 / 6), not here.
///
/// **Frame-step ergonomics at boundaries.** Per
/// [`plans/features/M3.md`](../../../plans/features/M3.md) §Risks, AVF
/// clamps `step(by:)` to `[0, duration]` internally — pressing `<` at
/// `.zero` or `>` at EOF is a silent no-op. The buttons stay enabled so
/// they don't appear broken mid-clip; only `.failed` disables them.
public struct Scrubber<Model: ScrubberModel>: View {

    /// The observable playback model. Marked `@Bindable` so SwiftUI tracks
    /// the macro-generated observation channels on the concrete conformer
    /// (`PlaybackController` or a mock).
    @Bindable public var model: Model

    public init(model: Model) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 8) {
            track
            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Track

    /// Slider bound to `currentTime` / `duration`. The slider value is a
    /// `Double` (seconds) because SwiftUI's `Slider` is `BinaryFloatingPoint`-
    /// constrained — `CMTime` doesn't fit. Conversions happen at the
    /// binding boundary.
    private var track: some View {
        Slider(
            value: Binding(
                get: { sliderSeconds },
                set: { newValue in
                    let target = CMTime(
                        seconds: newValue,
                        preferredTimescale: 600  // common AVF timescale
                    )
                    model.seek(to: target)
                }
            ),
            in: 0...sliderUpperBound
        )
        .disabled(!isTrackEnabled)
    }

    /// Seconds value the slider renders. Clamps to the slider's domain
    /// so out-of-range `currentTime` (rare, but possible mid-load) doesn't
    /// throw a SwiftUI runtime warning about the binding being outside
    /// the range.
    private var sliderSeconds: Double {
        let current = model.currentTime
        guard current.isValid, !current.isIndefinite else { return 0 }
        let seconds = CMTimeGetSeconds(current)
        return seconds.clamped(to: 0...sliderUpperBound)
    }

    /// Slider's upper bound in seconds. Falls back to a tiny positive
    /// value so `Slider` doesn't crash on a zero-width range while the
    /// asset is still loading.
    private var sliderUpperBound: Double {
        let duration = model.duration
        guard duration.isValid, !duration.isIndefinite else { return 1 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds > 0 ? seconds : 1
    }

    /// Track is disabled while the asset hasn't reported a valid duration
    /// yet, or when the source has failed. Mirrors the buttons' enablement.
    private var isTrackEnabled: Bool {
        let duration = model.duration
        let hasDuration =
            duration.isValid && !duration.isIndefinite
            && CMTimeGetSeconds(duration) > 0
        return hasDuration && !isFailed
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 24) {
            Spacer()
            stepBackButton
            playPauseButton
            stepForwardButton
            Spacer()
        }
    }

    private var stepBackButton: some View {
        Button {
            model.step(by: -1)
        } label: {
            Image(systemName: "backward.frame.fill")
                .imageScale(.large)
        }
        .accessibilityLabel("Step back one frame")
        .disabled(isFailed)
    }

    private var stepForwardButton: some View {
        Button {
            model.step(by: 1)
        } label: {
            Image(systemName: "forward.frame.fill")
                .imageScale(.large)
        }
        .accessibilityLabel("Step forward one frame")
        .disabled(isFailed)
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlay()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .imageScale(.large)
        }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .disabled(isFailed)
    }

    // MARK: - State helpers

    private var isPlaying: Bool {
        if case .running = model.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }
}

// MARK: - Clamp helper

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        if self < range.lowerBound { return range.lowerBound }
        if self > range.upperBound { return range.upperBound }
        return self
    }
}

// MARK: - Preview

#if DEBUG

/// AVF-free `ScrubberModel` used by the `#Preview` (and by
/// `ScrubberModelTests` to exercise the protocol contract).
///
/// `@MainActor @Observable` so the macro-generated tracking matches the
/// production `PlaybackController` — the scrubber view body reads the
/// same observation seams whether the model is a controller or this mock.
///
/// **Test-double side.** Every action call is recorded in
/// `recordedActions` so contract tests can assert "tapping play
/// triggered exactly one `togglePlay`" without needing to inspect AVF
/// state.
@MainActor
@Observable
public final class MockScrubberModel: ScrubberModel {

    public var currentTime: CMTime
    public var duration: CMTime
    public var state: SourceState

    /// Per-action call log. Preserves order so tests can assert sequence.
    public var recordedActions: [Action] = []

    public enum Action: Equatable, Sendable {
        case togglePlay
        case seek(CMTime)
        case step(Int)
    }

    public init(
        currentTime: CMTime = .zero,
        duration: CMTime = CMTime(value: 10, timescale: 1),
        state: SourceState = .idle
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.state = state
    }

    public func togglePlay() {
        recordedActions.append(.togglePlay)
        switch state {
        case .running: state = .idle
        case .failed: return
        default: state = .running
        }
    }

    public func seek(to time: CMTime) {
        recordedActions.append(.seek(time))
        // Clamp like `PlaybackSource.seek` does — preview slider drag
        // should look frame-accurate.
        let lower = (CMTimeCompare(time, .zero) < 0) ? .zero : time
        let upper: CMTime
        if duration.isValid, !duration.isIndefinite,
            CMTimeCompare(lower, duration) > 0
        {
            upper = duration
        } else {
            upper = lower
        }
        currentTime = upper
    }

    public func step(by count: Int) {
        recordedActions.append(.step(count))
        // Approximate a 30-fps step in preview-land.
        let delta = CMTime(value: CMTimeValue(count), timescale: 30)
        let target = currentTime + delta
        seek(to: target)
        // `seek` recorded itself; pop that so step doesn't appear as
        // `[step, seek]` in the action log.
        let lastWasSeek: Bool = {
            guard let last = recordedActions.last else { return false }
            if case .seek = last { return true }
            return false
        }()
        if lastWasSeek {
            recordedActions.removeLast()
        }
    }
}

#Preview("Scrubber · idle") {
    Scrubber(
        model: MockScrubberModel(
            currentTime: CMTime(value: 3, timescale: 1),
            duration: CMTime(value: 10, timescale: 1),
            state: .idle
        )
    )
    .frame(width: 360)
    .padding()
}

#Preview("Scrubber · running") {
    Scrubber(
        model: MockScrubberModel(
            currentTime: CMTime(value: 7, timescale: 1),
            duration: CMTime(value: 10, timescale: 1),
            state: .running
        )
    )
    .frame(width: 360)
    .padding()
}

#Preview("Scrubber · failed") {
    Scrubber(
        model: MockScrubberModel(
            currentTime: .zero,
            duration: CMTime(value: 10, timescale: 1),
            state: .failed(.assetLoadFailed(URL(fileURLWithPath: "/dev/null")))
        )
    )
    .frame(width: 360)
    .padding()
}

#endif
