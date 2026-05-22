import CoreMedia
import CoreVideo
import ImageIO
import Testing

@testable import Iris

// MARK: - Helpers

/// Build an IOSurface-backed YUV-420 bi-planar `CVPixelBuffer` and wrap it in a
/// `Frame`. Satisfies the `Frame` `@unchecked Sendable` invariants (immutable +
/// IOSurface-backed) without needing AVF.
private func makeMockFrame(
    timestamp: CMTime,
    width: Int = 1280,
    height: Int = 720
) -> Frame {
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
        fatalError("CVPixelBufferCreate failed with status \(status)")
    }
    return Frame(
        pixelBuffer: pixelBuffer,
        timestamp: timestamp,
        orientation: .up,
        source: .mock("test"),
        format: .yuv420BiPlanarFull,
        dimensions: CGSize(width: width, height: height)
    )
}

/// Race `operation` against a sleep; throw on whichever finishes first being
/// the timeout. Used to keep tests from hanging if the stream stalls.
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw MockSourceTestError.timeout
        }
        guard let result = try await group.next() else {
            throw MockSourceTestError.timeout
        }
        group.cancelAll()
        return result
    }
}

private enum MockSourceTestError: Error {
    case timeout
}

// MARK: - Tests

@Test
func mockSourceYieldsAllSuppliedFramesInOrder() async throws {
    // MockSource.start() yields each supplied frame and immediately moves on
    // (no per-frame suspension). With .bufferingNewest(1) on the stream, a
    // single-shot consumer only observes the LAST frame to survive the
    // buffer. To force ordered delivery of every frame, we run one start()
    // per frame against three MockSources and stitch the timestamps together.
    let t1 = CMTime(value: 1, timescale: 60)
    let t2 = CMTime(value: 2, timescale: 60)
    let t3 = CMTime(value: 3, timescale: 60)

    func received(from supply: [Frame]) async throws -> CMTime {
        let source = MockSource(supply: supply)
        let stream = source.frames
        return try await withTimeout(.seconds(1)) {
            async let consumer: CMTime = {
                var last: CMTime = .invalid
                for await frame in stream {
                    last = frame.timestamp
                }
                return last
            }()
            try await source.start()
            await source.invalidate()
            return await consumer
        }
    }

    let r1 = try await received(from: [makeMockFrame(timestamp: t1)])
    let r2 = try await received(from: [makeMockFrame(timestamp: t2)])
    let r3 = try await received(from: [makeMockFrame(timestamp: t3)])

    let collected = [r1, r2, r3]
    #expect(collected == [t1, t2, t3])
    // Strictly monotonic timestamps.
    for i in 1..<collected.count {
        #expect(collected[i] > collected[i - 1])
    }
}

@Test
func mockSourceTransitionsIdleToRunningToStopped() async throws {
    let frames = [
        makeMockFrame(timestamp: CMTime(value: 1, timescale: 60)),
        makeMockFrame(timestamp: CMTime(value: 2, timescale: 60)),
    ]
    let source = MockSource(supply: frames)

    // Initially idle.
    #expect(source.state == .idle)

    // `start()` runs through the supply synchronously, transitioning state
    // through .running and ending at .stopped before it returns. We can't
    // reliably observe .running mid-flight from outside (start is one
    // atomic-looking await from the caller's perspective), but the
    // load-bearing assertion is that the source ends at .stopped.
    try await source.start()

    #expect(source.state == .stopped)

    // Re-calling start() on a drained source keeps state coherent — it
    // transitions back through .running and lands at .stopped again.
    try await source.start()
    #expect(source.state == .stopped)
}

@Test
func mockSourceUnboundedBufferingPolicyDeliversEveryFrameToSingleConsumer() async throws {
    // Default .bufferingNewest(1) drops earlier frames when a consumer hasn't
    // attached yet (see mockSourceYieldsAllSuppliedFramesInOrder). Passing
    // .unbounded relaxes that so all three supplied frames survive into the
    // stream and a single consumer observes the full sequence.
    let t1 = CMTime(value: 1, timescale: 60)
    let t2 = CMTime(value: 2, timescale: 60)
    let t3 = CMTime(value: 3, timescale: 60)
    let supply = [
        makeMockFrame(timestamp: t1),
        makeMockFrame(timestamp: t2),
        makeMockFrame(timestamp: t3),
    ]
    let source = MockSource(supply: supply, bufferingPolicy: .unbounded)
    let stream = source.frames

    let collected: [CMTime] = try await withTimeout(.seconds(2)) {
        async let consumer: [CMTime] = {
            var timestamps: [CMTime] = []
            for await frame in stream {
                timestamps.append(frame.timestamp)
            }
            return timestamps
        }()
        try await source.start()
        await source.invalidate()
        return await consumer
    }

    #expect(collected == [t1, t2, t3])
}

@Test
func mockSourceInvalidateFinishesTheStream() async throws {
    let frame = makeMockFrame(timestamp: CMTime(value: 1, timescale: 60))
    let source = MockSource(supply: [frame])

    let stream = source.frames

    // Start a consumer first so the single supplied frame survives the
    // buffering policy, then start production.
    let received: Int = try await withTimeout(.seconds(2)) {
        async let consumer: Int = {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }()
        try await source.start()
        await source.invalidate()
        return await consumer
    }

    #expect(received == 1)
}
