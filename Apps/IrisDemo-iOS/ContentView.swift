import SwiftUI

/// iOS demo root. As of M9·P3·4 the `TabView` (Playback / Image / Capture tabs
/// + the `InspectorHandoff` conduit) is retired in favor of the shared,
/// cross-platform `IrisShell` — the same shell macOS adopted in P3·2. One shell
/// holds all coordinators for its lifetime (no per-tab disappear/reload), the
/// sidebar drives model selection + page navigation + per-page Open…/RECENT,
/// and Capture's camera lifecycle keys off the active-page selection (not view
/// `.onDisappear`). On iPhone the sidebar collapses to a drawer and the
/// inspector becomes a bottom sheet (P3·6).
struct ContentView: View {
    var body: some View {
        IrisShell()
    }
}
