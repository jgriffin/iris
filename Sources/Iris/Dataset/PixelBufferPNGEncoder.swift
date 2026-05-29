import CoreImage
import CoreVideo
import Foundation

/// Encodes a `CVPixelBuffer` (the YUV-420 bi-planar buffers `PlaybackSource`
/// produces, or any `CoreImage`-readable format) to PNG `Data`.
///
/// ## Why this lives here, and why it's new
///
/// M7·P3's "Opens · Image-encoding location" asked whether an existing
/// `Overlay`-side `CIImage`/`CGImage` path could be reused for PNG export, to
/// avoid duplicating coordinate/format logic. **It cannot** — there is no such
/// path. `Sources/Iris/Overlay/` draws `[Detection]` over a *live*
/// `AVPlayerLayer` / `Canvas`; the frame pixels are never lifted into a
/// `CIImage`/`CGImage` (the overlay composites on top of the AVF-owned video
/// layer). A repo-wide search for `CIContext` / `CIImage` / `CGImage` /
/// `CGImageDestination` / `pngData` finds nothing. So PNG export is genuinely
/// new surface, and it belongs next to its only consumer (`DatasetBuilder`),
/// not bolted onto the overlay path it shares no logic with.
///
/// ## Implementation
///
/// `CIImage(cvPixelBuffer:)` reads the bi-planar YUV buffer directly (CoreImage
/// handles the YCbCr→RGB conversion), and `CIContext.pngRepresentation` encodes
/// to PNG without ever touching UIKit/AppKit — so this compiles and runs
/// identically on iOS and macOS (the dataset target is both).
///
/// The `CIContext` is created once and reused; it is internally thread-safe per
/// CoreImage's contract, and this type carries no other mutable state, so it is
/// safe to share. `sRGB` is used as the output color space for a portable PNG.
public struct PixelBufferPNGEncoder: Sendable {

    /// Errors raised while encoding.
    public enum EncodeError: Error {
        /// CoreImage produced no PNG data for the buffer (unexpected — a
        /// readable IOSurface-backed buffer should always encode).
        case pngEncodingFailed
    }

    /// Reused CoreImage context. `CIContext` is documented thread-safe, so a
    /// single shared instance backs all encodes from a given encoder.
    private let context: CIContext

    /// Output color space for the PNG. sRGB keeps the file portable.
    private let colorSpace: CGColorSpace

    public init() {
        // `useSoftwareRenderer: false` lets CoreImage pick the GPU (MPS-backed
        // on Apple silicon) when available; it falls back to CPU otherwise.
        self.context = CIContext(options: [.useSoftwareRenderer: false])
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Encode `pixelBuffer` to PNG `Data`.
    ///
    /// - Note: the buffer is read as-is in its native pixel orientation. Frame
    ///   `orientation` metadata is not applied here — `PlaybackSource` emits
    ///   `.up` frames, so the stored PNG matches what the playback path decodes.
    public func pngData(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard
            let data = context.pngRepresentation(
                of: image,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [:]
            )
        else {
            throw EncodeError.pngEncodingFailed
        }
        return data
    }
}
