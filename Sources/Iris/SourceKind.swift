/// Identifies the origin of a `Frame` — useful for diagnostics, routing,
/// and disambiguating multi-source pipelines.
public enum SourceKind: Sendable, Hashable {
    /// Camera capture. The associated `String` is the `AVCaptureDevice.UniqueID`.
    /// Phase 3 introduces `CameraDevice`; this case may be refactored to
    /// `case camera(CameraDevice.ID)` then. Both spellings are `String`-typed
    /// so the change is source-compatible at the value level.
    case camera(String)

    /// File playback, identified by the asset's stable handle.
    case playback(AssetID)

    /// Test / preview source, labelled with a freeform tag.
    case mock(String)
}
