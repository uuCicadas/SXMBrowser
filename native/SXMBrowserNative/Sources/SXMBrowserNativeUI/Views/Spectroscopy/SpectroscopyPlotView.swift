import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct SpectroscopyMarkerLayer: View {
    let model: AppModel
    let file: SXMMetadata
    var isInteractive = false
    /// Explicit image rect in the layer's coordinate space. When nil the
    /// image is aspect-fit inside the available space (grid thumbnails).
    var rectOverride: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let rect = rectOverride ?? imageRect(in: proxy.size)
            ForEach(model.spectraForMarkers(on: file)) { spectrum in
                let visualStyle = spectrumVisualStyle(
                    for: spectrum
                )
                if let point = model.normalizedMarkerPosition(for: spectrum, on: file) {
                    let center = CGPoint(
                        x: rect.minX + point.x * rect.width,
                        y: rect.minY + point.y * rect.height
                    )
                    if isInteractive {
                        Button {
                            model.focusSingleSpectrum(spectrum)
                        } label: {
                            MeasurementMarker(
                                style: visualStyle,
                                isFocused:
                                    model.singleSpectroscopyState
                                        .focusedSpectrumID
                                        == spectrum.id
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .position(center)
                        .help(spectrum.filename)
                        .accessibilityLabel(
                            "Focus \(spectrum.filename)"
                        )
                        .accessibilityValue(
                            [
                                spectrumStyleDescription(
                                    visualStyle
                                ),
                                model.singleSpectroscopyState
                                    .focusedSpectrumID
                                    == spectrum.id
                                    ? "Focused spectrum"
                                    : "Spectrum marker",
                            ].joined(separator: ", ")
                        )
                        .accessibilityAddTraits(
                            model.singleSpectroscopyState
                                .focusedSpectrumID
                                == spectrum.id
                                ? .isSelected
                                : []
                        )
                    } else {
                        MeasurementMarker(
                            style: visualStyle
                        )
                        .position(center)
                    }
                }
            }
        }
        .allowsHitTesting(isInteractive)
    }

    private func imageRect(in size: CGSize) -> CGRect {
        let aspect = CGFloat(max(1, file.pixels.width)) / CGFloat(max(1, file.pixels.height))
        let available = CGRect(origin: .zero, size: size)
        let width: CGFloat
        let height: CGFloat
        if available.width / max(available.height, 1) > aspect {
            height = available.height
            width = height * aspect
        } else {
            width = available.width
            height = width / aspect
        }
        return CGRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
    }
}

struct MeasurementMarker: View {
    @Environment(\.colorScheme) private var colorScheme
    let style: SpectrumVisualStyle
    var isFocused = false

    var body: some View {
        let color = spectrumColor(style, for: colorScheme)
        ZStack {
            if isFocused {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .frame(width: 19, height: 19)
            }
            Circle()
                .fill(color)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: isFocused ? 1.8 : 1.3)
                )
                .frame(
                    width: isFocused ? 12 : 9.5,
                    height: isFocused ? 12 : 9.5
                )
                .shadow(color: .black.opacity(0.65), radius: 1.5)
        }
        // Keep the click target comfortable without covering more image data.
        .frame(width: 30, height: 30)
        .contentShape(Circle())
    }
}

struct SpectroscopyPlotCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel
    let presentation: PresentedSpectroscopyGroup

    private var group: SpectroscopyGroup {
        presentation.group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SpectroscopyPlotView(
                group: group,
                spectra: presentation.visibleSpectra,
                xColumn: model.spectrumXAxis(for: group),
                yColumn: model.spectrumYAxis(for: group)
            )
                .id(
                    "\(presentation.renderID)|"
                        + "\(model.spectrumXAxis(for: group))|"
                        + "\(model.spectrumYAxis(for: group))"
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                )

            Text(group.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            HStack {
                Text(group.kind.label)
                    .lineLimit(1)
                Spacer()
                Text(presentation.visibleCurveCountText)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.cardSurface(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.tileBorder(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.045), radius: 5, x: 0, y: 2)
        .help("\(group.title) for \(group.sxmFilename)")
    }
}

struct SpectroscopyPlotView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast

    let group: SpectroscopyGroup
    let spectra: [SpectroscopyFile]
    let xColumn: String
    let yColumn: String
    var focusedSpectrumID: SpectroscopyFile.ID? = nil
    var liveResizing = false

    private let inset = EdgeInsets(
        top: 20,
        leading: 68,
        bottom: 42,
        trailing: 14
    )

    var body: some View {
        Canvas { context, size in
            drawPlot(context: &context, size: size)
        }
        .background(AppTheme.plotCanvasBackground(for: colorScheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(group.title) spectroscopy plot"
        )
        .accessibilityValue(plotAccessibilityValue)
    }

    private func drawPlot(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(
            x: inset.leading,
            y: inset.top,
            width: max(1, size.width - inset.leading - inset.trailing),
            height: max(1, size.height - inset.top - inset.bottom)
        )

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(AppTheme.plotCanvasBackground(for: colorScheme))
        )

        let ranges = dataRanges()
        drawGridAndTicks(context: &context, plot: plot, ranges: ranges)
        drawFrame(context: &context, plot: plot)
        drawCurves(context: &context, plot: plot, ranges: ranges)

        drawKindBadge(context: &context, plot: plot)

        let axisColor = AppTheme.plotAxisText(for: colorScheme)
        context.draw(
            Text(xColumn)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(axisColor),
            at: CGPoint(x: plot.midX, y: size.height - 12),
            anchor: .center
        )
        var yLabelContext = context
        yLabelContext.translateBy(x: 11, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(
            Text(yColumn)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(axisColor),
            at: .zero,
            anchor: .center
        )
    }

    private func drawFrame(context: inout GraphicsContext, plot: CGRect) {
        context.stroke(
            Path(plot),
            with: .color(AppTheme.plotBorder(for: colorScheme)),
            lineWidth: 1
        )
    }

    private func drawGridAndTicks(
        context: inout GraphicsContext,
        plot: CGRect,
        ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)
    ) {
        let tickLength: CGFloat = 4
        let gridColor = AppTheme.plotMajorGrid(for: colorScheme)
        let zeroColor = AppTheme.plotZeroLine(for: colorScheme)
        let axisTextColor = AppTheme.plotAxisText(for: colorScheme)
        let borderColor = AppTheme.plotBorder(for: colorScheme)

        let xTicks = ScientificPlotTicks.ticks(
            min: ranges.xMin,
            max: ranges.xMax,
            targetCount: plot.width >= 220 ? 5 : 4
        )
        var lastDrawnX: CGFloat?
        for tick in xTicks {
            let x = plot.minX + CGFloat(tick.fraction) * plot.width
            let isZero = tick.value == 0
            var gridLine = Path()
            gridLine.move(to: CGPoint(x: x, y: plot.minY))
            gridLine.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(
                gridLine,
                with: .color(isZero ? zeroColor : gridColor),
                lineWidth: isZero ? 1.0 : 0.8
            )

            var tickPath = Path()
            tickPath.move(to: CGPoint(x: x, y: plot.maxY))
            tickPath.addLine(to: CGPoint(x: x, y: plot.maxY - tickLength))
            context.stroke(tickPath, with: .color(borderColor), lineWidth: 0.9)

            if let prev = lastDrawnX, abs(x - prev) < 40 {
                continue
            }
            lastDrawnX = x
            context.draw(
                Text(tick.label)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundColor(axisTextColor),
                at: CGPoint(x: x, y: plot.maxY + 7),
                anchor: .top
            )
        }

        let yTicks = ScientificPlotTicks.ticks(
            min: ranges.yMin,
            max: ranges.yMax,
            targetCount: plot.height >= 170 ? 5 : 4
        )
        var lastDrawnY: CGFloat?
        for tick in yTicks {
            let y = plot.maxY - CGFloat(tick.fraction) * plot.height
            let isZero = tick.value == 0
            var gridLine = Path()
            gridLine.move(to: CGPoint(x: plot.minX, y: y))
            gridLine.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                gridLine,
                with: .color(isZero ? zeroColor : gridColor),
                lineWidth: isZero ? 1.0 : 0.8
            )

            var tickPath = Path()
            tickPath.move(to: CGPoint(x: plot.minX, y: y))
            tickPath.addLine(to: CGPoint(x: plot.minX + tickLength, y: y))
            context.stroke(tickPath, with: .color(borderColor), lineWidth: 0.9)

            if let prev = lastDrawnY, abs(y - prev) < 15 {
                continue
            }
            lastDrawnY = y
            context.draw(
                Text(tick.label)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundColor(axisTextColor),
                at: CGPoint(x: plot.minX - 6, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawKindBadge(context: inout GraphicsContext, plot: CGRect) {
        let title = group.kind.label
        let badgeWidth = min(plot.width - 14, CGFloat(title.count) * 6.8 + 14)
        let badgeRect = CGRect(
            x: plot.minX + 6,
            y: plot.minY + 6,
            width: max(36, badgeWidth),
            height: 18
        )
        let path = Path(roundedRect: badgeRect, cornerRadius: 4)
        context.fill(path, with: .color(AppTheme.plotBadgeBackground(for: colorScheme)))
        context.stroke(path, with: .color(AppTheme.hairlineBorder(for: colorScheme)), lineWidth: 0.8)
        context.draw(
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(AppTheme.plotAxisText(for: colorScheme)),
            at: CGPoint(x: badgeRect.minX + 7, y: badgeRect.midY),
            anchor: .leading
        )
    }

    private func drawCurves(
        context: inout GraphicsContext,
        plot: CGRect,
        ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)
    ) {
        for spectrum in spectra where spectrum.id != focusedSpectrumID {
            drawCurve(
                spectrum,
                context: &context,
                plot: plot,
                ranges: ranges
            )
        }
        if let focused = spectra.first(where: {
            $0.id == focusedSpectrumID
        }) {
            drawCurve(
                focused,
                context: &context,
                plot: plot,
                ranges: ranges
            )
        }
    }

    private func drawCurve(
        _ spectrum: SpectroscopyFile,
        context: inout GraphicsContext,
        plot: CGRect,
        ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)
    ) {
        guard let series = group.columnSeries(
            for: spectrum,
            xColumn: xColumn,
            yColumn: yColumn
        ) else {
            return
        }
        let path = curvePath(
            series: series,
            plot: plot,
            ranges: ranges
        )
        let visualStyle = spectrumVisualStyle(
            for: spectrum
        )
        let strokeColor = spectrumColor(visualStyle, for: colorScheme)
        let isFocused = spectrum.id == focusedSpectrumID
        // While the drawer is being dragged the plot is redrawn every frame;
        // one decimated stroke per curve keeps the drag at full frame rate.
        if liveResizing {
            context.stroke(
                path,
                with: .color(strokeColor),
                style: spectrumStrokeStyle(
                    visualStyle.pattern,
                    lineWidth: 1.7
                )
            )
            return
        }
        let haloWidth: CGFloat
        let colorWidth: CGFloat
        if isFocused {
            haloWidth = colorSchemeContrast == .increased ? 5.6 : 4.8
            colorWidth = colorSchemeContrast == .increased ? 3.2 : 2.7
        } else {
            haloWidth = colorSchemeContrast == .increased ? 3.2 : 2.6
            colorWidth = colorSchemeContrast == .increased ? 2.1 : 1.75
        }
        if isFocused {
            context.stroke(
                path,
                with: .color(strokeColor.opacity(colorScheme == .dark ? 0.34 : 0.24)),
                style: spectrumStrokeStyle(
                    visualStyle.pattern,
                    lineWidth: haloWidth + 2.5,
                    lineCap: .butt
                )
            )
        }
        context.stroke(
            path,
            with: .color(AppTheme.plotCanvasBackground(for: colorScheme).opacity(0.88)),
            style: spectrumStrokeStyle(
                visualStyle.pattern,
                lineWidth: haloWidth,
                lineCap: .butt
            )
        )
        context.stroke(
            path,
            with: .color(strokeColor),
            style: spectrumStrokeStyle(
                visualStyle.pattern,
                lineWidth: colorWidth
            )
        )
    }

    private func curvePath(
        series: (x: [Double], y: [Double]),
        plot: CGRect,
        ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)
    ) -> Path {
        let count = min(series.x.count, series.y.count)
        let xSpan = max(1e-30, ranges.xMax - ranges.xMin)
        let ySpan = max(1e-30, ranges.yMax - ranges.yMin)
        var path = Path()
        var didMove = false
        func addPoint(_ xValue: Double, _ yValue: Double) {
            guard xValue.isFinite, yValue.isFinite else { return }
            let x = plot.minX
                + CGFloat((xValue - ranges.xMin) / xSpan) * plot.width
            let y = plot.maxY
                - CGFloat((yValue - ranges.yMin) / ySpan) * plot.height
            let point = CGPoint(x: x, y: y)
            if didMove {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                didMove = true
            }
        }

        let targetPoints = max(2, Int(plot.width / 2))
        guard liveResizing, count > targetPoints * 2 else {
            for index in 0..<count {
                addPoint(series.x[index], series.y[index])
            }
            return path
        }

        // Min/max decimation preserves peaks while cutting stroke work.
        let bucketCount = max(1, targetPoints)
        let bucketSize = max(1, count / bucketCount)
        var index = 0
        while index < count {
            let end = min(index + bucketSize, count)
            var lowest = Double.infinity
            var highest = -Double.infinity
            var lowestX = 0.0
            var highestX = 0.0
            for sample in index..<end {
                let x = series.x[sample]
                let y = series.y[sample]
                guard x.isFinite, y.isFinite else { continue }
                if y < lowest {
                    lowest = y
                    lowestX = x
                }
                if y > highest {
                    highest = y
                    highestX = x
                }
            }
            if lowest.isFinite {
                if lowestX <= highestX {
                    addPoint(lowestX, lowest)
                    addPoint(highestX, highest)
                } else {
                    addPoint(highestX, highest)
                    addPoint(lowestX, lowest)
                }
            }
            index = end
        }
        return path
    }

    private var plotAccessibilityValue: String {
        let curveText = spectra.count == 1
            ? "1 visible curve"
            : "\(spectra.count) visible curves"
        let focusedText: String
        if let focusedSpectrum = spectra.first(where: {
            $0.id == focusedSpectrumID
        }) {
            focusedText = ", focused \(focusedSpectrum.filename)"
        } else {
            focusedText = ""
        }
        let curveDetails = spectra.prefix(18).map {
            "\($0.filename), "
                + spectrumStyleDescription(for: $0)
        }.joined(separator: "; ")
        return "X axis \(xColumn), Y axis \(yColumn), "
            + curveText
            + ". Curves: \(curveDetails)"
            + focusedText
    }

    private func dataRanges() -> (xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        var xMin = Double.infinity
        var xMax = -Double.infinity
        var yMin = Double.infinity
        var yMax = -Double.infinity
        var hasX = false
        var hasY = false
        for spectrum in spectra {
            guard let series = group.columnSeries(
                for: spectrum,
                xColumn: xColumn,
                yColumn: yColumn
            ) else {
                continue
            }
            let count = min(series.x.count, series.y.count)
            for index in 0..<count {
                let x = series.x[index]
                let y = series.y[index]
                if x.isFinite {
                    xMin = Swift.min(xMin, x)
                    xMax = Swift.max(xMax, x)
                    hasX = true
                }
                if y.isFinite {
                    yMin = Swift.min(yMin, y)
                    yMax = Swift.max(yMax, y)
                    hasY = true
                }
            }
        }
        let resolvedXMin = hasX ? xMin : 0
        var resolvedXMax = hasX ? xMax : 1
        var resolvedYMin = hasY ? yMin : 0
        var resolvedYMax = hasY ? yMax : 1
        if resolvedXMax <= resolvedXMin {
            resolvedXMax = resolvedXMin + 1
        }
        if resolvedYMax <= resolvedYMin {
            resolvedYMax = resolvedYMin + 1
        }
        let yPad = (resolvedYMax - resolvedYMin) * 0.06
        resolvedYMin -= yPad
        resolvedYMax += yPad
        return (resolvedXMin, resolvedXMax, resolvedYMin, resolvedYMax)
    }
}

func spectrumVisualStyle(
    for spectrum: SpectroscopyFile
) -> SpectrumVisualStyle {
    SpectrumVisualStyle.resolve(
        index: spectrum.colorIndex
    )
}

func spectrumColor(
    _ style: SpectrumVisualStyle,
    for colorScheme: ColorScheme = .light
) -> Color {
    if colorScheme == .dark && style.paletteIndex == 6 {
        return Color(
            .sRGB,
            red: 0.88,
            green: 0.90,
            blue: 0.94,
            opacity: 1
        )
    }
    return Color(
        .sRGB,
        red: style.color.normalizedRed,
        green: style.color.normalizedGreen,
        blue: style.color.normalizedBlue,
        opacity: 1
    )
}

func spectrumStrokeStyle(
    _ pattern: SpectrumLinePattern,
    lineWidth: CGFloat,
    compact: Bool = false,
    lineCap: CGLineCap = .round
) -> StrokeStyle {
    let scale = compact ? 0.62 : 1
    return StrokeStyle(
        lineWidth: lineWidth,
        lineCap: lineCap,
        lineJoin: .round,
        dash: pattern.dashPattern.map {
            CGFloat($0) * scale
        }
    )
}

func spectrumStyleDescription(
    for spectrum: SpectroscopyFile
) -> String {
    spectrumStyleDescription(
        spectrumVisualStyle(for: spectrum)
    )
}

func spectrumStyleDescription(
    _ style: SpectrumVisualStyle
) -> String {
    let colorNames = [
        "Blue",
        "Vermilion",
        "Bluish green",
        "Reddish purple",
        "Orange",
        "Sky blue",
        "Black",
    ]
    let colorName = colorNames[style.paletteIndex]
    let patternName: String
    switch style.pattern {
    case .solid:
        patternName = "solid line"
    case .dashed:
        patternName = "dashed line"
    case .dotted:
        patternName = "dotted line"
    case .dashDot:
        patternName = "dash-dot line"
    }
    return "\(colorName), \(patternName)"
}


