import CoreML
import Foundation

/// Runtime loading helpers for Core ML models shipped as `.mlpackage`.
///
/// An `.mlpackage` is the *source* artifact: it must be compiled to an
/// `.mlmodelc` before `MLModel` can load it. Xcode does this at build time for
/// bundled resources, but Iris also supports compiling at runtime — for
/// file-picked models (M6·P3) and for the package's own fixture tests, which
/// keep the `.mlpackage` under `Tests/.../Fixtures/` and compile it on the
/// fly. The compiled output lands in a temp directory (`MLModel.compileModel`
/// returns the URL); Iris never commits an `.mlmodelc`.
///
/// **Concurrency.** A namespace of `static` helpers; no shared state.
public enum CoreMLModelLoading {

    /// Compile an `.mlpackage` (or `.mlmodel`) at `url` to an `.mlmodelc` and
    /// load the resulting `MLModel`.
    ///
    /// - Parameters:
    ///   - url: Location of the `.mlpackage` bundle (or a bare `.mlmodel`).
    ///   - computeUnits: Which compute units Core ML may use. Defaults to
    ///     `.all` (Neural Engine + GPU + CPU).
    /// - Returns: The loaded, compiled `MLModel`.
    /// - Throws: Whatever `MLModel.compileModel(at:)` /
    ///   `MLModel(contentsOf:configuration:)` throw (missing file, malformed
    ///   package, unsupported spec).
    public static func compileAndLoad(
        at url: URL,
        computeUnits: MLComputeUnits = .all
    ) async throws -> MLModel {
        // `compileModel(at:)` returns a temp-dir `.mlmodelc` URL. We load
        // immediately and let the OS reap the temp dir; the loaded `MLModel`
        // holds what it needs. (For long-lived bundled models a consumer would
        // cache the compiled URL, but the runtime-compile path here is for
        // tests + file-picked models where a fresh compile per launch is fine.)
        let compiledURL = try await MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    /// Synchronous variant of ``compileAndLoad(at:computeUnits:)``.
    ///
    /// Used by call sites that can't be `async` — notably the
    /// `DetectorCatalogEntry` factory closure, which is a synchronous
    /// `@MainActor () -> any Detector`. Compiling YOLOv12n's small package is
    /// a sub-second operation, so doing it inline at session-build time is
    /// acceptable for the demo; a production consumer with a large model would
    /// pre-compile off the main actor and cache the URL.
    ///
    /// Uses the synchronous `MLModel.compileModel(at:)` overload, which
    /// remains available on the 26 SDK alongside the async one.
    public static func compileAndLoadSync(
        at url: URL,
        computeUnits: MLComputeUnits = .all
    ) throws -> MLModel {
        let compiledURL = try MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    /// Load an already-compiled `.mlmodelc` directly, without compiling.
    ///
    /// This is the *bundled-resource* path: when an app target bundles an
    /// `.mlpackage`, Xcode compiles it to an `.mlmodelc` at build time, so the
    /// runtime resource is already compiled and should be loaded as-is. (The
    /// runtime-compile helpers above are for the `.mlpackage`-source path —
    /// tests and file-picked models.)
    public static func loadCompiled(
        at compiledURL: URL,
        computeUnits: MLComputeUnits = .all
    ) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }
}
