import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

// MARK: - ImageFrameDecoder

/// Decodes a single still image into an **upright, source-agnostic `Frame`** —
/// the M8 entry point that lets a captured/playback frame, a screenshot, or any
/// image on disk flow through the exact same detection + overlay pipeline as
/// capture and playback.
///
/// **Orientation is baked into the pixels here.** A still from disk may carry an
/// EXIF orientation (a HEIC photo, a rotated capture). This decoder applies that
/// orientation (CoreImage `.oriented`) so the returned `Frame` holds upright
/// pixels stamped `.up` — matching how Capture rotates on the `AVCaptureConnection`
/// and Playback delivers upright, and keeping `VideoGeometry` rotation-free
/// (its locked invariant: rotation/mirroring are resolved upstream, never in the
/// overlay). A consumer therefore feeds `frame.dimensions` straight to
/// `VideoGeometry(contentSize:)` and detections land correctly.
///
/// **No time axis.** A still has no PTS, so the `Frame` carries a frozen
/// timestamp (`.zero` by default). The image inspector (M8·P3) runs detection
/// one-shot rather than over a stream.
///
/// **Cross-platform.** Built on CoreImage + ImageIO + CoreVideo only — no
/// UIKit/AppKit — so it compiles and runs identically on iOS and macOS (the
/// image target is both). Mirrors `PixelBufferPNGEncoder`'s shared-`CIContext`
/// shape: `CIContext` is documented thread-safe, so a single instance backs all
/// decodes from a given decoder.
public struct ImageFrameDecoder: Sendable {

    /// Errors raised while decoding a still into a `Frame`.
    public enum DecodeError: Error, Sendable {
        /// ImageIO could not open the URL as an image source (missing file,
        /// unsupported container).
        case sourceUnreadable
        /// The image source held no decodable image at index 0.
        case imageDecodeFailed
        /// `CVPixelBufferCreate` failed with the carried status code.
        case pixelBufferAllocationFailed(CVReturn)
    }

    /// Reused CoreImage context. Thread-safe per CoreImage's contract; the type
    /// carries no other mutable state, so it is safe to share / `Sendable`.
    private let context: CIContext

    /// Working color space for the render. sRGB keeps decoded pixels portable
    /// and matches `PixelBufferPNGEncoder`'s export space.
    private let colorSpace: CGColorSpace

    public init() {
        // `useSoftwareRenderer: false` lets CoreImage pick the GPU when
        // available, CPU otherwise — same choice as the dataset encoder.
        self.context = CIContext(options: [.useSoftwareRenderer: false])
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    // MARK: - From a CGImage

    /// Build an upright `Frame` from `cgImage`, baking `orientation` into the
    /// pixels so the result is stamped `.up`.
    ///
    /// - Parameters:
    ///   - cgImage: The decoded image.
    ///   - orientation: The image's EXIF orientation, applied to produce upright
    ///     pixels. Defaults to `.up` (already-upright images — most PNGs /
    ///     screenshots).
    ///   - identifier: Stable handle carried on `Frame.source` (`.image(_)`).
    ///   - timestamp: Frozen presentation time. Defaults to `.zero` (a still has
    ///     no time axis).
    public func frame(
        from cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        identifier: String,
        timestamp: CMTime = .zero
    ) throws -> Frame {
        // Orient to upright. `.oriented` swaps width/height for the 90°/270°
        // cases, so `extent` is already the upright size. Normalize the extent
        // origin to (0,0) so the render bounds line up with the destination.
        var ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = ciImage.extent
        if extent.origin != .zero {
            ciImage = ciImage.transformed(
                by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            )
        }

        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        let pixelBuffer = try makePixelBuffer(width: width, height: height)

        context.render(
            ciImage,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )

        return Frame(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            orientation: .up,
            source: .image(identifier),
            format: .bgra8,
            dimensions: CGSize(width: width, height: height)
        )
    }

    // MARK: - From a file URL

    /// Load a still from `url` via ImageIO and build an upright `Frame`,
    /// reading the file's EXIF orientation from its metadata and baking it in.
    ///
    /// - Parameters:
    ///   - url: A readable image file (PNG, JPEG, HEIC, …).
    ///   - identifier: Stable handle carried on `Frame.source`. Defaults to the
    ///     file's last path component.
    ///   - timestamp: Frozen presentation time. Defaults to `.zero`.
    public func frame(
        fromImageAt url: URL,
        identifier: String? = nil,
        timestamp: CMTime = .zero
    ) throws -> Frame {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DecodeError.sourceUnreadable
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DecodeError.imageDecodeFailed
        }
        return try frame(
            from: cgImage,
            orientation: Self.orientation(of: source),
            identifier: identifier ?? url.lastPathComponent,
            timestamp: timestamp
        )
    }

    // MARK: - Private

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw DecodeError.pixelBufferAllocationFailed(status)
        }
        return pixelBuffer
    }

    /// Read the EXIF orientation from an image source's metadata, defaulting to
    /// `.up` when absent or unrecognized.
    private static func orientation(of source: CGImageSource) -> CGImagePropertyOrientation {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let raw = props[kCGImagePropertyOrientation] as? UInt32,
            let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
    }
}
