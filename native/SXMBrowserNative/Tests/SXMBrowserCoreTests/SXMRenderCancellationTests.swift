import Foundation
import Testing
@testable import SXMBrowserCore

private final class CheckpointCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationCount: Int
    private var storedCount = 0

    init(cancellationCount: Int) {
        self.cancellationCount = cancellationCount
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func check() throws {
        lock.lock()
        storedCount += 1
        let shouldCancel = storedCount >= cancellationCount
        lock.unlock()
        if shouldCancel {
            throw CancellationError()
        }
    }
}

private func catchesCancellation<T>(
    _ operation: () throws -> T
) -> Bool {
    do {
        _ = try operation()
        return false
    } catch is CancellationError {
        return true
    } catch {
        return false
    }
}

@Test
func rendererEntryPointsHonorPreCancellation() throws {
    let matrix = Matrix(
        width: 4,
        height: 4,
        values: Array(repeating: 3, count: 16)
    )
    let statistics = try #require(SXMRenderer.statistics(matrix))
    let cancelled = CancellationCheckpoint {
        throw CancellationError()
    }

    #expect(catchesCancellation {
        try SXMRenderer.processedMatrix(
            matrix,
            processing: .lineMean,
            cancellation: cancelled
        )
    })
    #expect(catchesCancellation {
        try SXMRenderer.statistics(matrix, cancellation: cancelled)
    })
    #expect(catchesCancellation {
        try SXMRenderer.histogram(
            matrix,
            statistics: statistics,
            bins: 64,
            cancellation: cancelled
        )
    })
    #expect(catchesCancellation {
        try SXMRenderer.colorize(
            matrix: matrix,
            palette: .gray,
            vmin: 0,
            vmax: 4,
            invert: false,
            cancellation: cancelled
        )
    })
}

@Test
func statisticsChecksCancellationDuringLargeLoops() {
    let matrix = Matrix(
        width: 256,
        height: 256,
        values: (0..<(256 * 256)).map(Float.init)
    )
    let counter = CheckpointCounter(cancellationCount: 5)
    let cancellation = CancellationCheckpoint {
        try counter.check()
    }

    #expect(catchesCancellation {
        try SXMRenderer.statistics(
            matrix,
            cancellation: cancellation
        )
    })
    #expect(counter.count == 5)
}
