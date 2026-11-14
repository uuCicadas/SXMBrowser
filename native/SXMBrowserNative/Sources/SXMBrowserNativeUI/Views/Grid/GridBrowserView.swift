import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct GridBrowserView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel

    var body: some View {
        // Build the grid model once per data change, not once per layout pass.
        // GeometryReader re-runs its closure on every animation frame, and the
        // display-item projection is O(files + spectra).
        let displayItems = model.visibleDisplayItems
        GeometryReader { geometry in
            let metrics = AdaptiveGridMetrics(
                containerWidth: Double(geometry.size.width),
                density: model.gridDensity
            )

            ZStack {
                AppTheme.gridStage(for: colorScheme)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: columns(for: metrics),
                            spacing: 16
                        ) {
                            ForEach(displayItems) { item in
                                switch item {
                                case .sxm(let file):
                                    ThumbnailCard(
                                        model: model,
                                        file: file
                                    )
                                    .id(item.id)
                                case .spectroscopy(let presentation):
                                    SpectroscopyPlotCard(
                                        model: model,
                                        presentation: presentation
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                        .padding(
                            CGFloat(metrics.horizontalPadding)
                        )
                    }
                    .background(AppTheme.gridStage(for: colorScheme))
                    .scrollContentBackground(.hidden)
                    .onAppear {
                        model.setGridNavigationColumnCount(
                            metrics.columnCount
                        )
                        scrollToSelection(with: proxy)
                    }
                    .onChange(of: metrics.columnCount) { _, newCount in
                        model.setGridNavigationColumnCount(newCount)
                        scrollToSelection(with: proxy)
                    }
                    .onChange(of: model.selectedID) { _, _ in
                        scrollToSelection(with: proxy)
                    }
                    .onChange(of: model.sortMode) { _, _ in
                        scrollToSelection(with: proxy)
                    }
                    .onChange(of: model.sortAscending) { _, _ in
                        scrollToSelection(with: proxy)
                    }
                    .onChange(of: model.gridDensity) { _, _ in
                        scrollToSelection(with: proxy)
                    }
                    .onChange(of: model.activeTagID) { _, _ in
                        scrollToSelection(with: proxy)
                    }
                }
            }
            .background(AppTheme.gridStage(for: colorScheme))
        }
        .background(AppTheme.gridStage(for: colorScheme))
    }

    private func columns(
        for metrics: AdaptiveGridMetrics
    ) -> [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(
                    minimum: CGFloat(metrics.minimumCardWidth)
                ),
                spacing: CGFloat(metrics.spacing)
            ),
            count: metrics.columnCount
        )
    }

    private func scrollToSelection(with proxy: ScrollViewProxy) {
        guard let selectedID = model.selectedID else { return }
        let targetID = "sxm-\(selectedID.uuidString)"
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }
}

extension GridDensity {
    var label: String {
        switch self {
        case .compact:
            "Compact"
        case .comfortable:
            "Comfortable"
        case .large:
            "Large"
        }
    }
}

