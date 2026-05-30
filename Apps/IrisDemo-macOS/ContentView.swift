import SwiftUI

/// macOS demo root. As of M9·P3·2 the donor split-shell (the `Videos | Images`
/// segmented picker + both coordinators + the playback/image detail + inspector)
/// has been lifted into the shared, cross-platform `IrisShell`. macOS simply
/// renders it. The former per-mode picker is replaced by the sidebar's
/// page-rows (Playback / Image); Capture is present-but-disabled (no camera on
/// macOS). The Min-confidence slider now lives in the sidebar MODEL section.
struct ContentView: View {
    var body: some View {
        IrisShell()
    }
}
