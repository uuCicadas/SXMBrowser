import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct HistogramView: View {
    let model: AppModel
    @State private var dragMode: DragMode?

    enum DragMode {
        case min
        case max
        case range(offsetMin: Double, offsetMax: Double)
    }

    private let inset = EdgeInsets(top: 12, leading: 62, bottom: 26, trailing: 12)

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                drawHistogram(context: &context, size: size)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.035, green: 0.036, blue: 0.040))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
        guard let stats = model.selectedStats else {
            context.draw(
                Text("No histogram").font(.caption).foregroundColor(.white.opacity(0.65)),
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

        drawGrid(context: &context, plot: plot, stats: stats)
        drawPaletteRail(context: &context, plot: plot)

        let yUpper = yForValue(upper, plot: plot, min: fullMin, max: fullMax)
        let yLower = yForValue(lower, plot: plot, min: fullMin, max: fullMax)
        let selectedRect = CGRect(x: plot.minX, y: min(yUpper, yLower), width: plot.width, height: abs(yLower - yUpper))
        context.fill(Path(roundedRect: selectedRect, cornerRadius: 3), with: .color(AppTheme.histogramHandle.opacity(0.10)))

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
        context.fill(outline, with: .color(AppTheme.histogramFill.opacity(0.28)))
        context.stroke(outline, with: .color(AppTheme.histogramStroke), lineWidth: 1.25)

        drawScaleHandle(context: &context, plot: plot, value: upper, min: fullMin, max: fullMax, label: compact(upper), isUpper: true)
        drawScaleHandle(context: &context, plot: plot, value: lower, min: fullMin, max: fullMax, label: compact(lower), isUpper: false)

        context.draw(Text(compact(fullMax)).font(.caption2).foregroundColor(.white.opacity(0.72)), at: CGPoint(x: 8, y: plot.minY + 1), anchor: .leading)
        context.draw(Text(compact((fullMax + fullMin) / 2)).font(.caption2).foregroundColor(.white.opacity(0.54)), at: CGPoint(x: 8, y: plot.midY), anchor: .leading)
        context.draw(Text(compact(fullMin)).font(.caption2).foregroundColor(.white.opacity(0.72)), at: CGPoint(x: 8, y: plot.maxY - 1), anchor: .leading)
        context.draw(Text("0%").font(.caption2).foregroundColor(.white.opacity(0.72)), at: CGPoint(x: plot.minX, y: plot.maxY + 17), anchor: .topLeading)
        context.draw(Text("max").font(.caption2).foregroundColor(.white.opacity(0.72)), at: CGPoint(x: plot.maxX, y: plot.maxY + 17), anchor: .topTrailing)
    }

    private func drawGrid(context: inout GraphicsContext, plot: CGRect, stats: HistogramStats) {
        for i in 0...6 {
            let y = plot.minY + plot.height * CGFloat(i) / 6
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(path, with: .color(.white.opacity(i == 0 || i == 6 ? 0.18 : 0.075)), lineWidth: 1)
        }

        for i in 0...4 {
            let x = plot.minX + plot.width * CGFloat(i) / 4
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(.white.opacity(i == 0 ? 0.18 : 0.065)), lineWidth: 1)
        }
    }

    private func drawPaletteRail(context: inout GraphicsContext, plot: CGRect) {
        let rail = CGRect(x: plot.minX - 18, y: plot.minY, width: 6, height: plot.height)
        let stops = PaletteStore.shared.stops(for: model.selectedPalette)
        let steps = max(2, Int(plot.height))
        for idx in 0..<steps {
            let t = Double(idx) / Double(steps - 1)
            let sample = model.invertPalette ? t : 1 - t
            let color = paletteColor(stops: stops, at: sample)
            let rect = CGRect(x: rail.minX, y: rail.minY + CGFloat(idx), width: rail.width, height: 1.4)
            context.fill(Path(rect), with: .color(color))
        }
        context.stroke(Path(roundedRect: rail, cornerRadius: 2), with: .color(.white.opacity(0.30)), lineWidth: 0.7)
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
        let y = yForValue(value, plot: plot, min: min, max: max)
        var line = Path()
        line.move(to: CGPoint(x: plot.minX - 8, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(AppTheme.histogramHandle), lineWidth: 1.8)

        let knob = CGRect(x: plot.minX - 12, y: y - 6, width: 12, height: 12)
        context.fill(Path(ellipseIn: knob), with: .color(AppTheme.histogramHandle))
        context.stroke(Path(ellipseIn: knob), with: .color(.white.opacity(0.9)), lineWidth: 0.8)

        let labelWidth: CGFloat = Swift.min(96, Swift.max(54, CGFloat(label.count) * 7 + 12))
        let labelRect = CGRect(
            x: plot.maxX - labelWidth - 6,
            y: Swift.min(plot.maxY - 23, Swift.max(plot.minY + 2, y + (isUpper ? 4 : -22))),
            width: labelWidth,
            height: 19
        )
        context.fill(Path(roundedRect: labelRect, cornerRadius: 4), with: .color(Color.black.opacity(0.68)))
        context.stroke(Path(roundedRect: labelRect, cornerRadius: 4), with: .color(AppTheme.histogramHandle.opacity(0.72)), lineWidth: 0.8)
        context.draw(Text(label).font(.caption2).foregroundColor(.white), at: CGPoint(x: labelRect.midX, y: labelRect.midY))
    }

    private func handleDrag(_ value: DragGesture.Value, size: CGSize) {
        guard let stats = model.selectedStats else { return }
        let plot = plotRect(size)
        let y = min(plot.maxY, max(plot.minY, value.location.y))
        let dataValue = stats.max - Double((y - plot.minY) / plot.height) * (stats.max - stats.min)
        let lo = model.scaleMin ?? stats.p1
        let hi = model.scaleMax ?? stats.p99

        if dragMode == nil {
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

    private func paletteColor(stops: [PaletteStop], at value: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return .gray }
        if value <= first.position { return Color(red: first.r, green: first.g, blue: first.b) }
        if value >= last.position { return Color(red: last.r, green: last.g, blue: last.b) }
        for idx in 0..<(stops.count - 1) {
            let a = stops[idx]
            let b = stops[idx + 1]
            if value >= a.position && value <= b.position {
                let span = Swift.max(1e-12, b.position - a.position)
                let t = (value - a.position) / span
                return Color(
                    red: a.r * (1 - t) + b.r * t,
                    green: a.g * (1 - t) + b.g * t,
                    blue: a.b * (1 - t) + b.b * t
                )
            }
        }
        return Color(red: last.r, green: last.g, blue: last.b)
    }
}

