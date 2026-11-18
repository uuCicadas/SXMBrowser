import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct HistogramView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel
    @State private var dragMode: DragMode?

    enum DragMode {
        case min
        case max
        case range(offsetMin: Double, offsetMax: Double)
    }

    private let inset = EdgeInsets(top: 12, leading: 78, bottom: 26, trailing: 12)

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                drawHistogram(context: &context, size: size)
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppTheme.plotCanvasBackground(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value, size: proxy.size)
                    }
                    .onEnded { _ in dragMode = nil }
            )
        }
    }

    private func drawHistogram(context: inout GraphicsContext, size: CGSize) {
        let axisTextColor = AppTheme.plotAxisText(for: colorScheme)
        guard let stats = model.selectedStats else {
            context.draw(
                Text("No histogram").font(.caption).foregroundColor(axisTextColor.opacity(0.8)),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let plot = plotRect(size)
        let fullMin = stats.min
        let fullMax = stats.max
        let scaleMin = max(fullMin, min(fullMax, model.scaleMin ?? stats.p1))
        let scaleMax = max(fullMin, min(fullMax, model.scaleMax ?? stats.p99))
        let lower = min(scaleMin, scaleMax)
        let upper = max(scaleMin, scaleMax)

        let yTicks = ScientificPlotTicks.ticks(min: fullMin, max: fullMax, targetCount: 4)
        drawGrid(context: &context, plot: plot, yTicks: yTicks)
        drawPaletteRail(context: &context, plot: plot)

        let yUpper = yForValue(upper, plot: plot, min: fullMin, max: fullMax)
        let yLower = yForValue(lower, plot: plot, min: fullMin, max: fullMax)
        let clipColor = AppTheme.histogramClipOverlay(for: colorScheme)
        if yUpper > plot.minY {
            let topClip = CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: yUpper - plot.minY)
            context.fill(Path(topClip), with: .color(clipColor))
        }
        if yLower < plot.maxY {
            let bottomClip = CGRect(x: plot.minX, y: yLower, width: plot.width, height: plot.maxY - yLower)
            context.fill(Path(bottomClip), with: .color(clipColor))
        }

        let selectedRect = CGRect(x: plot.minX, y: min(yUpper, yLower), width: plot.width, height: abs(yLower - yUpper))
        context.fill(
            Path(roundedRect: selectedRect, cornerRadius: 2),
            with: .color(AppTheme.histogramHandleStroke(for: colorScheme).opacity(0.08))
        )

        let maxCount = max(1, stats.hist.max() ?? 1)
        var outline = Path()
        outline.move(to: CGPoint(x: plot.minX, y: plot.maxY))

        for idx in stats.hist.indices {
            let edgeMid = (stats.edges[idx] + stats.edges[idx + 1]) / 2
            let y = yForValue(edgeMid, plot: plot, min: fullMin, max: fullMax)
            let fraction = sqrt(Double(stats.hist[idx]) / Double(maxCount))
            let x = plot.minX + CGFloat(fraction) * plot.width
            outline.addLine(to: CGPoint(x: x, y: y))
        }
        outline.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        context.fill(outline, with: .color(AppTheme.histogramBarFill(for: colorScheme).opacity(0.36)))
        context.stroke(outline, with: .color(AppTheme.histogramBarStroke(for: colorScheme)), lineWidth: 1.35)

        drawScaleHandle(context: &context, plot: plot, value: upper, min: fullMin, max: fullMax, label: compact(upper), isUpper: true)
        drawScaleHandle(context: &context, plot: plot, value: lower, min: fullMin, max: fullMax, label: compact(lower), isUpper: false)

        if yTicks.count >= 2 {
            var lastDrawnY: CGFloat?
            for tick in yTicks.reversed() {
                let y = plot.maxY - CGFloat(tick.fraction) * plot.height
                if let prev = lastDrawnY, abs(y - prev) < 15 { continue }
                lastDrawnY = y
                context.draw(
                    Text(tick.label)
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundColor(axisTextColor),
                    at: CGPoint(x: plot.minX - 24, y: y),
                    anchor: .trailing
                )
            }
        } else {
            context.draw(
                Text(compact(fullMax)).font(.caption2.monospacedDigit()).foregroundColor(axisTextColor),
                at: CGPoint(x: plot.minX - 24, y: plot.minY + 1),
                anchor: .trailing
            )
            context.draw(
                Text(compact(fullMin)).font(.caption2.monospacedDigit()).foregroundColor(axisTextColor),
                at: CGPoint(x: plot.minX - 24, y: plot.maxY - 1),
                anchor: .trailing
            )
        }
        context.draw(Text("0").font(.caption2.monospacedDigit()).foregroundColor(axisTextColor), at: CGPoint(x: plot.minX, y: plot.maxY + 16), anchor: .topLeading)
        context.draw(Text("peak").font(.caption2).foregroundColor(axisTextColor), at: CGPoint(x: plot.maxX, y: plot.maxY + 16), anchor: .topTrailing)
    }

    private func drawGrid(context: inout GraphicsContext, plot: CGRect, yTicks: [ScientificAxisTick]) {
        let gridColor = AppTheme.plotMajorGrid(for: colorScheme)
        let borderColor = AppTheme.plotBorder(for: colorScheme)

        context.stroke(Path(plot), with: .color(borderColor.opacity(0.7)), lineWidth: 1)

        for tick in yTicks {
            let y = plot.maxY - CGFloat(tick.fraction) * plot.height
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
        }

        for i in 1...3 {
            let x = plot.minX + plot.width * CGFloat(i) / 4
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(gridColor.opacity(0.8)), lineWidth: 1)
        }
    }

    private func drawPaletteRail(context: inout GraphicsContext, plot: CGRect) {
        let rail = CGRect(x: plot.minX - 18, y: plot.minY, width: 7, height: plot.height)
        let stops = PaletteStore.shared.stops(for: model.selectedPalette)
        let gradient = Gradient(
            stops: stops.map {
                Gradient.Stop(
                    color: Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: 1),
                    location: $0.position
                )
            }
        )
        let startPoint = model.invertPalette
            ? CGPoint(x: rail.midX, y: rail.minY)
            : CGPoint(x: rail.midX, y: rail.maxY)
        let endPoint = model.invertPalette
            ? CGPoint(x: rail.midX, y: rail.maxY)
            : CGPoint(x: rail.midX, y: rail.minY)
        let railPath = Path(roundedRect: rail, cornerRadius: 2.5)
        context.fill(
            railPath,
            with: .linearGradient(gradient, startPoint: startPoint, endPoint: endPoint)
        )
        context.stroke(railPath, with: .color(AppTheme.plotBorder(for: colorScheme)), lineWidth: 0.8)
    }

    private func drawScaleHandle(
        context: inout GraphicsContext,
        plot: CGRect,
        value: Double,
        min: Double,
        max: Double,
        label: String,
        isUpper: Bool
    ) {
        let handleColor = AppTheme.histogramHandleStroke(for: colorScheme)
        let y = yForValue(value, plot: plot, min: min, max: max)
        var line = Path()
        line.move(to: CGPoint(x: plot.minX - 8, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(handleColor), lineWidth: 1.8)

        let knob = CGRect(x: plot.minX - 12, y: y - 5.5, width: 11, height: 11)
        context.fill(Path(ellipseIn: knob), with: .color(handleColor))
        context.stroke(Path(ellipseIn: knob), with: .color(AppTheme.plotCanvasBackground(for: colorScheme)), lineWidth: 1.2)

        let labelWidth: CGFloat = Swift.min(96, Swift.max(54, CGFloat(label.count) * 7 + 12))
        let labelRect = CGRect(
            x: plot.maxX - labelWidth - 6,
            y: Swift.min(plot.maxY - 22, Swift.max(plot.minY + 3, y + (isUpper ? 4 : -22))),
            width: labelWidth,
            height: 18
        )
        context.fill(Path(roundedRect: labelRect, cornerRadius: 4), with: .color(AppTheme.plotBadgeBackground(for: colorScheme)))
        context.stroke(Path(roundedRect: labelRect, cornerRadius: 4), with: .color(handleColor.opacity(0.75)), lineWidth: 0.9)
        context.draw(
            Text(label).font(.caption2.monospacedDigit()).foregroundColor(AppTheme.plotAxisText(for: colorScheme)),
            at: CGPoint(x: labelRect.midX, y: labelRect.midY)
        )
    }

    private func handleDrag(_ value: DragGesture.Value, size: CGSize) {
        guard let stats = model.selectedStats else { return }
        let plot = plotRect(size)
        let y = min(plot.maxY, max(plot.minY, value.location.y))
        let dataValue = stats.max - Double((y - plot.minY) / plot.height) * (stats.max - stats.min)
        let lo = model.scaleMin ?? stats.p1
        let hi = model.scaleMax ?? stats.p99

        if dragMode == nil {
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            let minY = yForValue(lo, plot: plot, min: stats.min, max: stats.max)
            let maxY = yForValue(hi, plot: plot, min: stats.min, max: stats.max)
            if abs(y - minY) < 16 {
                dragMode = .min
            } else if abs(y - maxY) < 16 {
                dragMode = .max
            } else {
                dragMode = .range(offsetMin: dataValue - lo, offsetMax: dataValue - hi)
            }
        }

        switch dragMode {
        case .min:
            model.updateScale(min: min(dataValue, hi - 1e-30), max: hi)
        case .max:
            model.updateScale(min: lo, max: max(dataValue, lo + 1e-30))
        case .range(let offsetMin, let offsetMax):
            var newLo = dataValue - offsetMin
            var newHi = dataValue - offsetMax
            let width = newHi - newLo
            if newLo < stats.min {
                newLo = stats.min
                newHi = newLo + width
            }
            if newHi > stats.max {
                newHi = stats.max
                newLo = newHi - width
            }
            model.updateScale(min: newLo, max: newHi)
        case nil:
            break
        }
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(
            x: inset.leading,
            y: inset.top,
            width: max(1, size.width - inset.leading - inset.trailing),
            height: max(1, size.height - inset.top - inset.bottom)
        )
    }

    private func yForValue(_ value: Double, plot: CGRect, min: Double, max: Double) -> CGFloat {
        let span = Swift.max(1e-30, max - min)
        return plot.maxY - CGFloat((value - min) / span) * plot.height
    }
}

