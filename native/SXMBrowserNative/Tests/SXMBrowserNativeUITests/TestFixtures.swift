import AppKit
import Foundation
import SXMBrowserCore

func makeTestSXM(
    filename: String,
    modifiedOffset: TimeInterval = 0,
    recordedOffset: TimeInterval? = nil
) -> SXMMetadata {
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    return SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/sxm-test/\(filename)"),
        filename: filename,
        header: [:],
        recordedTime: recordedOffset.map { baseDate.addingTimeInterval($0) },
        modifiedTime: baseDate.addingTimeInterval(modifiedOffset),
        pixels: (width: 128, height: 128),
        scanRange: (x: 10e-9, y: 10e-9),
        scanOffset: (x: 0, y: 0),
        scanAngle: 0,
        scanDir: "up",
        zControllerOn: true,
        channels: [
            SXMChannel(
                name: "Z",
                unit: "m",
                directions: [.fwd, .bwd],
                kind: .topography
            ),
        ],
        defaultChannel: "Z"
    )
}

func makeTestImage() -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16))
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func trigger() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isTriggered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
