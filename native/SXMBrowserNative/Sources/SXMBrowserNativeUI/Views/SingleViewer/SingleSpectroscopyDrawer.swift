import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct SingleSpectroscopyDrawer: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel
    @Binding var liveHeight: CGFloat
    @Binding var isResizing: Bool
    let maximumHeight: CGFloat

    private var displayedHeight: CGFloat {
        min(liveHeight, maximumHeight)
    }
    @State private var dragStartHeight: CGFloat?
    @State private var isLegendPopoverPresented = false

    private var groups: [PresentedSpectroscopyGroup] {
        guard let file = model.selectedFile else { return [] }
        return model.presentedSpectrumGroups(for: file)
    }

    private var presentation:
        SingleSpectroscopyDrawerPresentation
    {
        SingleSpectroscopyDrawerPresentation(
            groups: groups,
            activeGroupID:
                model.singleSpectroscopyState.activeGroupID
        )
    }

    private var isExpanded: Bool {
        model.singleSpectroscopyState.isExpanded
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                resizeHandle
            }

            drawerHeader

            if isExpanded {
                Divider()
                drawerContent
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: isExpanded ? displayedHeight : 42,
            maxHeight: isExpanded ? displayedHeight : 42
        )
        .background(
            AppTheme.cardSurface(for: colorScheme)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.separator.opacity(0.8))
                .frame(height: 1)
        }
        .clipped()
        .browserMotion(.disclosure, value: isExpanded)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(
                        isResizing
                            ? Color.accentColor.opacity(0.8)
                            : Color.secondary.opacity(0.35)
                    )
                    .frame(width: 42, height: 3)
            }
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .onTapGesture(count: 2) {
                let defaultHeight = CGFloat(
                    SingleSpectroscopyState.defaultHeight
                )
                liveHeight = defaultHeight
                model.setSingleSpectroscopyDrawerHeight(
                    defaultHeight
                )
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = displayedHeight
                            isResizing = true
                        }
                        let start =
                            dragStartHeight ?? displayedHeight
                        let next = SingleSpectroscopyState
                            .resizedHeight(
                                startingAt: Double(start),
                                verticalTranslation: Double(
                                    value.translation.height
                                )
                            )
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            liveHeight = min(CGFloat(next), maximumHeight)
                        }
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                        isResizing = false
                        model.setSingleSpectroscopyDrawerHeight(
                            liveHeight
                        )
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(
                "Spectroscopy drawer height"
            )
            .accessibilityValue(
                "\(Int(liveHeight.rounded())) points"
            )
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment:
                    delta = 20
                case .decrement:
                    delta = -20
                @unknown default:
                    return
                }
                let next = SingleSpectroscopyState.clampedHeight(
                    Double(liveHeight) + delta
                )
                liveHeight = CGFloat(next)
                model.setSingleSpectroscopyDrawerHeight(
                    liveHeight
                )
            }
    }

    private var drawerHeader: some View {
        GeometryReader { proxy in
            drawerHeaderRow(compact: proxy.size.width < 430)
        }
        .frame(height: isExpanded ? 34 : 42)
    }

    private func drawerHeaderRow(
        compact: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Button {
                model.setSingleSpectroscopyDrawerExpanded(
                    !isExpanded
                )
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(
                isExpanded
                    ? "Collapse spectroscopy"
                    : "Expand spectroscopy"
            )
            .accessibilityLabel(
                isExpanded
                    ? "Collapse spectroscopy drawer"
                    : "Expand spectroscopy drawer"
            )

            if !compact {
                Text("Spectroscopy")
                    .font(.headline)
            }

            if groups.count > 1 {
                Picker(
                    "Spectrum group",
                    selection: Binding(
                        get: {
                            presentation.activeGroup?.id ?? ""
                        },
                        set: {
                            model
                                .activateSingleSpectroscopyGroup(
                                    $0
                                )
                        }
                    )
                ) {
                    ForEach(
                        Array(groups.enumerated()),
                        id: \.element.id
                    ) { index, group in
                        Text(
                            "Group \(index + 1): "
                                + "\(group.group.title) · "
                                + group.columnSummary
                        )
                        .tag(group.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: compact ? 145 : 240)
                .accessibilityLabel("Spectrum group")
            } else if let activeGroup =
                presentation.activeGroup {
                Text(activeGroup.group.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: compact ? 155 : nil)
            } else if compact {
                Text("Spectroscopy")
                    .font(.headline)
            }

            Spacer(minLength: 8)

            if presentation.activeGroup != nil {
                Text(
                    compact
                        ? "\(presentation.visibleCount)"
                            + "/\(presentation.totalCount)"
                        : presentation.visibleCountText
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(AppTheme.subtleFill)
                    )
                    .accessibilityLabel(
                        presentation.visibleCountText
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var drawerContent: some View {
        switch presentation.availability {
        case .noAssociatedSpectra:
            drawerEmptyState(
                icon: "waveform.path.ecg",
                title: "No Associated Spectra",
                message:
                    "Associate DAT files in the sidebar to "
                    + "show a spectrum here."
            )
        case .activeGroupHasNoVisibleCurves, .ready:
            if let activeGroup = presentation.activeGroup {
                drawerGroupContent(activeGroup)
            }
        }
    }

    private func drawerGroupContent(
        _ activeGroup: PresentedSpectroscopyGroup
    ) -> some View {
        GeometryReader { proxy in
            if proxy.size.width >= 560 {
                let legendWidth = min(
                    CGFloat(220),
                    max(CGFloat(190), proxy.size.width * 0.28)
                )
                HStack(spacing: 10) {
                    drawerPlot(activeGroup)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )

                    SpectroscopyLegend(
                        model: model,
                        presentation: activeGroup
                    )
                    .equatable()
                    .frame(width: legendWidth)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                ZStack(alignment: .topTrailing) {
                    drawerPlot(activeGroup)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )

                    Button {
                        isLegendPopoverPresented.toggle()
                    } label: {
                        Label(
                            "Curves \(activeGroup.visibleSpectra.count)"
                                + "/\(activeGroup.allSpectra.count)",
                            systemImage: "list.bullet"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(8)
                    .popover(
                        isPresented:
                            $isLegendPopoverPresented,
                        arrowEdge: .bottom
                    ) {
                        SpectroscopyLegend(
                            model: model,
                            presentation: activeGroup
                        )
                        .equatable()
                        .frame(width: 310, height: 320)
                    }
                    .accessibilityLabel(
                        "Show spectrum curve legend"
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func drawerPlot(
        _ activeGroup: PresentedSpectroscopyGroup
    ) -> some View {
        if activeGroup.visibleSpectra.isEmpty {
            drawerEmptyState(
                icon: "eye.slash",
                title: "No Visible Curves in This Group",
                message:
                    "Use the curve legend to show a spectrum "
                    + "and restore the plot."
            )
            .background(
                AppTheme.imageWell(for: colorScheme)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        AppTheme.tileBorder(for: colorScheme),
                        lineWidth: 1
                    )
            }
        } else {
            let xColumn = model.spectrumXAxis(
                for: activeGroup.group
            )
            let yColumn = model.spectrumYAxis(
                for: activeGroup.group
            )
            SpectroscopyPlotView(
                group: activeGroup.group,
                spectra: activeGroup.visibleSpectra,
                xColumn: xColumn,
                yColumn: yColumn,
                focusedSpectrumID:
                    model.singleSpectroscopyState
                        .focusedSpectrumID,
                liveResizing: isResizing
            )
            .id(
                "\(activeGroup.renderID)|"
                    + "\(xColumn)|\(yColumn)"
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        AppTheme.tileBorder(for: colorScheme),
                        lineWidth: 1
                    )
            }
        }
    }

    private func drawerEmptyState(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct SpectroscopyLegend: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel
    let presentation: PresentedSpectroscopyGroup
    let focusedSpectrumID: SpectroscopyFile.ID?
    let canModifyVisibility: Bool

    init(
        model: AppModel,
        presentation: PresentedSpectroscopyGroup
    ) {
        self.model = model
        self.presentation = presentation
        focusedSpectrumID = model.singleSpectroscopyState.focusedSpectrumID
        canModifyVisibility = model.canModifySpectrumVisibility
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Curves")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(
                    "\(presentation.visibleSpectra.count)"
                        + "/\(presentation.allSpectra.count)"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(presentation.allSpectra) {
                        spectrum in
                        SpectroscopyLegendRow(
                            model: model,
                            spectrum: spectrum
                        )
                    }
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(AppTheme.elevatedCard(for: colorScheme))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    AppTheme.hairlineBorder(for: colorScheme),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spectrum curve legend")
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.presentation.id == rhs.presentation.id
            && lhs.presentation.allSpectra.map(\.id)
                == rhs.presentation.allSpectra.map(\.id)
            && lhs.presentation.visibleSpectra.map(\.id)
                == rhs.presentation.visibleSpectra.map(\.id)
            && lhs.focusedSpectrumID == rhs.focusedSpectrumID
            && lhs.canModifyVisibility == rhs.canModifyVisibility
    }
}

private struct SpectroscopyLegendRow: View {
    let model: AppModel
    let spectrum: SpectroscopyFile

    private var isVisible: Bool {
        model.isSpectrumVisible(spectrum)
    }

    private var isFocused: Bool {
        model.singleSpectroscopyState.focusedSpectrumID
            == spectrum.id
    }

    var body: some View {
        HStack(spacing: 7) {
            Toggle(
                "Show \(spectrum.filename)",
                isOn: Binding(
                    get: { isVisible },
                    set: {
                        model.setSpectrum(
                            spectrum,
                            visible: $0
                        )
                    }
                )
            )
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 16)
            .disabled(!model.canModifySpectrumVisibility)

            Button {
                model.focusSingleSpectrum(spectrum)
            } label: {
                HStack(spacing: 7) {
                    SpectrumStyleGlyph(spectrum: spectrum)
                        .opacity(isVisible ? 1 : 0.72)

                    Text(spectrum.filename)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(
                            isVisible
                                ? Color.primary
                                : Color.secondary
                        )

                    Spacer(minLength: 0)

                    if isFocused {
                        Image(systemName: "scope")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if !isVisible {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isVisible)
            .accessibilityLabel(spectrum.filename)
            .accessibilityValue(
                [
                    spectrumStyleDescription(
                        for: spectrum
                    ),
                    isVisible ? "Visible" : "Hidden",
                    isFocused ? "Focused" : "Not focused",
                ].joined(separator: ", ")
            )
            .accessibilityAddTraits(
                isFocused ? .isSelected : []
            )
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isFocused
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isFocused
                        ? Color.accentColor.opacity(0.55)
                        : Color.clear,
                    lineWidth: 1
                )
        }
        .help(
            isVisible
                ? "\(spectrum.filename) — Click to focus"
                : "\(spectrum.filename) — Show to focus"
        )
    }
}

