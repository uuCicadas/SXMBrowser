import AppKit
import Foundation
import Observation
import SXMBrowserAppCore
import SXMBrowserCore

@Observable
@MainActor
public final class ThumbnailPipeline {
    public typealias ImageRenderer = @MainActor (
        _ file: SXMMetadata,
        _ channel: String,
        _ direction: ScanDirection,
        _ processing: ProcessingMode,
        _ palette: PaletteName,
        _ invert: Bool
    ) async -> UncheckedSendableImage?

    private struct ThumbnailTaskEntry {
        let token: UUID
        let task: Task<UncheckedSendableImage?, Never>
        var waiterIDs: Set<UUID>
    }

    @ObservationIgnored private let thumbnailCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var thumbnailTasks: [String: ThumbnailTaskEntry] = [:]
    @ObservationIgnored private let thumbnailLimiter: AsyncLimiter
    @ObservationIgnored private let imageRenderer: ImageRenderer

    public convenience init(
        renderCoordinator: RenderCoordinator,
        concurrencyLimit: Int = 4,
        countLimit: Int = 256,
        totalCostLimit: Int = 64 * 1024 * 1024
    ) {
        self.init(
            concurrencyLimit: concurrencyLimit,
            countLimit: countLimit,
            totalCostLimit: totalCostLimit,
            imageRenderer: { file, channel, direction, processing, palette, invert in
                do {
                    if Task.isCancelled { return nil }
                    let matrix = try await renderCoordinator.matrix(
                        for: file,
                        key: MatrixKey(channel: channel, direction: direction),
                        priority: .utility
                    )
                    if Task.isCancelled { return nil }
                    let options = RenderOptions(
                        channel: channel,
                        direction: direction,
                        processing: processing,
                        palette: palette,
                        outputSize: 260,
                        invert: invert,
                        transparentMissingValues: true
                    )
                    return try await runDetachedCancellable(priority: .utility) {
                        UncheckedSendableImage(
                            try SXMRenderer.renderImage(
                                matrix: matrix,
                                options: options,
                                cancellation: .task
                            )
                        )
                    }
                } catch {
                    return nil
                }
            }
        )
    }

    public init(
        concurrencyLimit: Int = 4,
        countLimit: Int = 256,
        totalCostLimit: Int = 64 * 1024 * 1024,
        imageRenderer: @escaping ImageRenderer
    ) {
        self.thumbnailLimiter = AsyncLimiter(limit: concurrencyLimit, order: .lifo)
        self.imageRenderer = imageRenderer
        thumbnailCache.countLimit = countLimit
        thumbnailCache.totalCostLimit = totalCostLimit
    }

    public static func cacheKey(
        for file: SXMMetadata,
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode,
        palette: PaletteName,
        invert: Bool
    ) -> String {
        let modifiedBits = String(
            file.modifiedTime.timeIntervalSince1970.bitPattern,
            radix: 16
        )
        return "\(file.path.path)|\(modifiedBits)|thumb|\(channel)|\(direction.rawValue)|\(processing.rawValue)|\(palette.rawValue)|\(invert)"
    }

    public func thumbnail(
        for file: SXMMetadata,
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode,
        palette: PaletteName,
        invert: Bool
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = Self.cacheKey(
            for: file,
            channel: channel,
            direction: direction,
            processing: processing,
            palette: palette,
            invert: invert
        )
        if let cached = thumbnailCache.object(forKey: key as NSString) {
            return cached
        }

        let waiterID = UUID()
        let entry: ThumbnailTaskEntry
        if var existing = thumbnailTasks[key] {
            existing.waiterIDs.insert(waiterID)
            thumbnailTasks[key] = existing
            entry = existing
        } else {
            let token = UUID()
            let task = Task { @MainActor [weak self] () -> UncheckedSendableImage? in
                guard let self else { return nil }
                return await self.generateThumbnail(
                    for: file,
                    cacheKey: key,
                    channel: channel,
                    direction: direction,
                    processing: processing,
                    palette: palette,
                    invert: invert
                )
            }
            let created = ThumbnailTaskEntry(
                token: token,
                task: task,
                waiterIDs: [waiterID]
            )
            thumbnailTasks[key] = created
            entry = created
        }

        let image = await withTaskCancellationHandler {
            await entry.task.value?.image
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelThumbnailWaiter(
                    waiterID,
                    forKey: key,
                    token: entry.token
                )
            }
        }
        if var current = thumbnailTasks[key], current.token == entry.token {
            current.waiterIDs.remove(waiterID)
            if current.waiterIDs.isEmpty {
                thumbnailTasks.removeValue(forKey: key)
            } else {
                thumbnailTasks[key] = current
            }
        }
        return Task.isCancelled ? nil : image
    }

    public func invalidateAll() {
        thumbnailCache.removeAllObjects()
        cancelAll()
    }

    public func cancelAll() {
        for entry in thumbnailTasks.values {
            entry.task.cancel()
        }
        thumbnailTasks.removeAll()
    }

    internal func cachedImage(forKey key: String) -> NSImage? {
        thumbnailCache.object(forKey: key as NSString)
    }

    internal var waitingCount: Int {
        get async {
            await thumbnailLimiter.waiterCount
        }
    }

    private func cancelThumbnailWaiter(
        _ waiterID: UUID,
        forKey key: String,
        token: UUID
    ) {
        guard var entry = thumbnailTasks[key], entry.token == token else {
            return
        }
        entry.waiterIDs.remove(waiterID)
        if entry.waiterIDs.isEmpty {
            thumbnailTasks.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            thumbnailTasks[key] = entry
        }
    }

    private func generateThumbnail(
        for file: SXMMetadata,
        cacheKey: String,
        channel: String,
        direction: ScanDirection,
        processing: ProcessingMode,
        palette: PaletteName,
        invert: Bool
    ) async -> UncheckedSendableImage? {
        guard await thumbnailLimiter.acquire() else {
            return nil
        }
        defer {
            Task {
                await thumbnailLimiter.release()
            }
        }

        if Task.isCancelled { return nil }
        guard let rendered = await imageRenderer(
            file,
            channel,
            direction,
            processing,
            palette,
            invert
        ) else {
            return nil
        }
        let image = rendered.image
        if Task.isCancelled { return nil }
        thumbnailCache.setObject(
            image,
            forKey: cacheKey as NSString,
            cost: Self.estimatedImageCost(image)
        )
        return UncheckedSendableImage(image)
    }

    private static func estimatedImageCost(_ image: NSImage) -> Int {
        let width = max(1, Int(image.size.width.rounded(.up)))
        let height = max(1, Int(image.size.height.rounded(.up)))
        return width * height * 4
    }
}
