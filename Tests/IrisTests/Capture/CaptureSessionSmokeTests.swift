#if os(iOS) && !targetEnvironment(simulator)
import Testing
import CoreMedia
@testable import Iris

private enum TestFailure: Error {
    case streamEnded
    case timeout
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestFailure.timeout
        }
        guard let result = try await group.next() else {
            throw TestFailure.timeout
        }
        group.cancelAll()
        return result
    }
}

@Test
func captureSessionDeliversFramesOnDevice() async throws {
    let session = CaptureSession()
    try await session.start()
    defer { Task { await session.invalidate() } }

    let firstFrame = try await withTimeout(.seconds(3)) {
        var iter = session.frames.makeAsyncIterator()
        guard let frame = await iter.next() else {
            throw TestFailure.streamEnded
        }
        return frame
    }

    #expect(firstFrame.dimensions.width > 0)
    #expect(firstFrame.dimensions.height > 0)
    #expect(firstFrame.format == .yuv420BiPlanarFull)
}
#endif
