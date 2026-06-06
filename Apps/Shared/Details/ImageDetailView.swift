import CoreImage
import CoreMedia
import CoreVideo
import Iris
import SwiftUI

/// The reusable still-image inspector detail, shared by both demo targets — the
/// image-page analogue of `PlaybackContentView` / macOS `ContentView`'s
/// playback detail, **minus the scrubber and playback controls** (a still has
/// no time axis). Renders the held image with the `DetectionLayer` overlay on
/// top, a detector picker, and a "Tune" sheet (the same Tuning → Live
/// detections → Metrics stack the playback page presents).
///
/// **Why this is shared.** Both platform containers (iOS tab, macOS Images
/// mode) own their own coordinator + picker state and file-picking chrome, but
/// the *detail rendering* is identical. Lifting it here keeps the composition
/// (overlay geometry, picker, tuning sheet) in one place; the containers pass
/// in their coordinator + bindings and keep platform-specific chrome out.
///
/// **Rendering the pixels behind the overlay.** The image is drawn straight
/// from `coordinator.frame`'s upright `CVPixelBuffer` (the decoder already baked
/// EXIF orientation into the pixels and stamped the frame `.up`). A shared
/// `CIContext` renders that buffer to a `CGImage` once per held frame, shown via
/// the cross-platform `Image(decorative:scale:orientation:)` — no `UIImage` /
/// `NSImage` gating, and the displayed pixels are exactly the pixels the
/// detector saw, so the overlay boxes land correctly. The overlay sits in the
/// SAME `ZStack` frame as a `GeometryReader`-measured `.aspectFit` image, so
/// `VideoGeometry(contentSize: frame.dimensions, containerSize: <frame>,
/// .aspectFit)` lines the detections up on the displayed image — identical to
/// the playback path, just with a frozen `displayTime`.
struct ImageDetailView: View {
    let coordinator: ImageDetectionCoordinator
    let catalog: DetectorCatalog
    let recentDetectors: RecentDetectors
    let modelStore: DemoModelStore
    @Binding var selectedDetectorID: String
    @Binding var showTuning: Bool

    /// Whether to render the built-in control bar (detector picker + Tune). The
    /// unified shell (M9·P3) owns model selection in its sidebar MODEL section,
    /// so it hosts this view with `showsControlBar: false` — the bar is
    /// suppressed there rather than deleted (the old standalone containers still
    /// rely on it). Defaults to `true` for those callers.
    var showsControlBar: Bool = true

    /// The shared app-wide selection — read for its render-time
    /// ``ModelSelection/overlayFilter`` (M9·P3 floor, generalized M10). Injected
    /// at both app roots.
    @Environment(ModelSelection.self) private var modelSelection

    /// Shared CoreImage context for the held-frame → `CGImage` render. Thread-
    /// safe per CoreImage's contract; reused across renders.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.frame != nil {
                imageArea
            } else {
                emptyState
            }
            // M9·P1·A6: the control bar is always present so its disabled state
            // is visible — the detector picker + Tune are gated on a loaded frame
            // (no model controls interactive over an empty canvas). They light up
            // the moment `coordinator.frame` becomes non-nil.
            //
            // M9·P3: suppressed when hosted in the unified shell, which owns
            // model selection in its sidebar MODEL section and the Tune toggle in
            // its toolbar — the bar would be a redundant second picker there.
            if showsControlBar {
                controlBar
            }
        }
        .sheet(isPresented: $showTuning) {
            tuningSheet
        }
    }

    // MARK: - Image + overlay

    /// The decoded image with the `DetectionLayer` overlay on top. Image and
    /// overlay share one `GeometryReader`-measured frame; the overlay derives
    /// its display box from `VideoGeometry(.aspectFit)` over the frame's upright
    /// dimensions, so boxes land on the displayed pixels.
    @ViewBuilder
    private var imageArea: some View {
        ZStack {
            if let cgImage = renderedImage {
                Image(decorative: cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            DetectionLayer(
                store: coordinator.resultStore,
                makeConverter: { [coordinator] size in
                    // Runs at draw time inside DetectionLayer's GeometryReader,
                    // which SwiftUI evaluates on MainActor — reading the
                    // MainActor-isolated coordinator is safe. Assert it to
                    // satisfy the `@Sendable` signature without a hop.
                    MainActor.assumeIsolated {
                        VideoGeometry(
                            contentSize: coordinator.frame?.dimensions ?? .zero,
                            containerSize: size,
                            contentMode: .aspectFit
                        )
                    }
                },
                stalenessThreshold: coordinator.resultStore.playbackStalenessThreshold,
                tuning: coordinator.session?.router,
                // M9·P3 floor, generalized M10, store-keyed M12·P3: render-time
                // overlay filter for the active detector, assembled by the store
                // from its slice + the global floor. Reading the observed store +
                // selection here re-runs `body` when any knob (global floor,
                // per-label floor, hidden set) changes, so the held still
                // re-filters live (pure draw-time filter — no re-detection).
                filter: modelSelection.labelStore.overlayFilter(
                    for: modelSelection.detectorID,
                    globalFloor: modelSelection.minConfidence
                ),
                displayTimeSource: { [coordinator] in
                    MainActor.assumeIsolated { coordinator.frame?.timestamp ?? .zero }
                }
            )
            .allowsHitTesting(false)

            metricsHUD
        }
    }

    /// Render the held frame's upright pixel buffer to a `CGImage` for display.
    /// `nil` before any image is set. Recomputed when `coordinator.frame`
    /// changes (the held buffer is immutable per image, so this is one render
    /// per pick / re-pick).
    private var renderedImage: CGImage? {
        guard let frame = coordinator.frame else { return nil }
        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        return Self.ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Top-trailing HUD pill showing the best-effort pipeline gauge (inference
    /// ms + processed count; a still has no stream so drop/emit stay zero).
    @ViewBuilder
    private var metricsHUD: some View {
        VStack {
            HStack {
                Spacer()
                Text(coordinator.metrics.compactSummary)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Control bar

    /// Detector picker + "Tune" button — the persistent control row below the
    /// image. Mirrors the playback control bar minus the file-pick button (the
    /// containers own the platform-specific pick affordance).
    @ViewBuilder
    private var controlBar: some View {
        // M9·P1·A6: no model controls over an empty canvas. Both the picker and
        // the Tune toggle are disabled until a frame is loaded.
        let hasFrame = coordinator.frame != nil
        HStack {
            Picker("Detector", selection: $selectedDetectorID) {
                ForEach(recentDetectors.sortedEntries(catalog)) { entry in
                    detectorRow(for: entry).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Active detector")
            .disabled(!hasFrame)

            Spacer()

            Button {
                showTuning = true
            } label: {
                Label("Tune", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .accessibilityLabel("Tune detector")
            .disabled(!hasFrame)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        #if os(iOS)
        .background(Color(.secondarySystemBackground))
        #endif
    }

    /// One picker row, annotated with availability — a `.modelNotReady` entry
    /// (the unloaded file-pick slot) is dimmed. Mirrors the playback picker row.
    @ViewBuilder
    private func detectorRow(for entry: DetectorCatalogEntry) -> some View {
        if modelStore.availability(forEntryID: entry.id) == .modelNotReady {
            Text(entry.displayName).foregroundStyle(.secondary)
        } else {
            Text(entry.displayName)
        }
    }

    // MARK: - Tuning sheet

    /// The same Tuning → Live detections → Metrics sheet the playback page
    /// presents, with the still's frozen `displayTime` (`frame.timestamp`).
    @ViewBuilder
    private var tuningSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let session = coordinator.session {
                        sheetSection("Tuning") {
                            session.settingsView
                                .frame(minHeight: 240)
                        }
                    }

                    Divider()

                    sheetSection("Live detections") {
                        if coordinator.frame != nil {
                            DetectionInspector(
                                store: coordinator.resultStore,
                                displayTimeSource: { [coordinator] in
                                    coordinator.frame?.timestamp ?? .zero
                                },
                                stalenessThreshold: coordinator.resultStore.playbackStalenessThreshold
                            )
                        } else {
                            Text("Pick an image to inspect detections.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 280, alignment: .top)

                    Divider()

                    sheetSection("Metrics") {
                        DetectionMetricsView(metrics: coordinator.metrics)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Detector tuning")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTuning = false }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty state

    /// Shown when no image is held — a CTA pointing at the container's picker.
    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No image", systemImage: "photo")
        } description: {
            Text("Pick an image to run detectors on it.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
