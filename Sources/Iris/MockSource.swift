import Foundation

/// A deterministic `Source` that yields a fixed sequence of pre-built frames.
/// Used by SwiftUI `#Preview`s and tests so the rest of the pipeline can be
/// exercised without an AVF-backed source.
///
/// Invariants justifying `@unchecked Sendable`:
///   1. All mutable state (`_state`) is guarded by `lock` (an `NSLock`).
///   2. `supply` is immutable after `init`.
///   3. `AsyncStream.Continuation` is itself documented thread-safe.
public final class MockSource: Source, @unchecked Sendable {

    // MARK: - Stored state

    private let _frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let lock = NSLock()
    private var _state: SourceState = .idle
    private let supply: [Frame]

    // MARK: - Init

    public init(supply: [Frame]) {
        let (stream, cont) = AsyncStream.makeStream(
            of: Frame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self._frames = stream
        self.continuation = cont
        self.supply = supply
    }

    // MARK: - Source

    public var frames: AsyncStream<Frame> { _frames }

    public var state: SourceState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public func start() async throws {
        setState(.running)
        for frame in supply {
            continuation.yield(frame)
        }
        setState(.stopped)
    }

    public func stop() async {
        setState(.stopped)
    }

    public func invalidate() async {
        continuation.finish()
    }

    // MARK: - Private

    private func setState(_ newValue: SourceState) {
        lock.lock()
        _state = newValue
        lock.unlock()
    }
}
