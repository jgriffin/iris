import Foundation

/// The shell's active page. Routes both the sidebar's active-row expansion and
/// the detail pane. Capture is offered everywhere in the type but rendered
/// disabled where there is no camera (macOS).
enum ShellPage: String, CaseIterable, Identifiable, Hashable {
    case playback, image, capture
    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: return "Playback"
        case .image: return "Image"
        case .capture: return "Capture"
        }
    }

    var systemImage: String {
        switch self {
        case .playback: return "play.rectangle"
        case .image: return "photo"
        case .capture: return "camera"
        }
    }
}
