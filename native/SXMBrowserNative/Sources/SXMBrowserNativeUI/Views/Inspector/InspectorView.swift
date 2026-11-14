import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

    var isSingle: Bool { model.mode == .single && model.selectedFile != nil }
    var canEditScanDisplay: Bool { model.selectedFile != nil && !model.files.isEmpty }
    private var metadataPresentation:
        InspectorMetadataPresentation?
    {
        model.selectedFile.map {
            InspectorMetadataPresentation(
                metadata: $0,
                selectedChannelName: model.selectedChannel
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorSection(title: "File Information") {
                    if let file = model.selectedFile,
                       let metadataPresentation {
                        InspectorMetadataRow(
                            "File",
                            file.filename
                        )
                        InspectorMetadataRow(
                            "Recorded",
                            metadataPresentation.recordedTime.map {
                                formattedMetadataDate($0)
                            } ?? "Not recorded"
                        )
                        InspectorMetadataRow(
                            "Modified",
                            formattedMetadataDate(
                                metadataPresentation.modifiedTime
                            )
                        )
                        InspectorMetadataRow(
                            "Dimensions",
                            "\(metadataPresentation.pixelWidth)"
                                + " × "
                                + "\(metadataPresentation.pixelHeight)"
                                + " px"
                        )
                        InspectorMetadataRow(
                            "Scan range",
                            formattedInspectorPair(
                                metadataPresentation
                                    .scanRangeMeters,
                                separator: " × "
                            )
                        )
                        InspectorMetadataRow(
                            "Offset",
                            formattedInspectorPair(
                                metadataPresentation
                                    .scanOffsetMeters,
                                separator: " · ",
                                includesAxisNames: true
                            )
                        )
                        InspectorMetadataRow(
                            "Angle",
                            formattedInspectorAngle(
                                metadataPresentation
                                    .scanAngleDegrees
                            )
                        )
                        InspectorMetadataRow(
                            "Channel",
                            formattedInspectorChannel(
                                metadataPresentation
                            )
                        )
                    } else {
                        Text("No file selected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                InspectorSection(title: "Scan Display") {
                    LabeledControl("Channel") {
                        Picker("Channel", selection: Binding(
                            get: { model.selectedChannel },
                            set: {
                                model.selectedChannel = $0
                                model.channelChanged()
                            }
                        )) {
                            ForEach(model.selectedFile?.channels ?? []) { channel in
                                Text(channel.name).tag(channel.name)
                            }
                        }
                        .labelsHidden()
                    }

                    LabeledControl("Direction") {
                        Picker("Direction", selection: Binding(
                            get: { model.selectedDirection },
                            set: {
                                model.selectedDirection = $0
                                model.controlsChanged(resetScale: true)
                            }
                        )) {
                            ForEach(model.selectedChannelInfo?.directions ?? [], id: \.self) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    LabeledControl("Processing") {
                        Picker("Processing", selection: Binding(
                            get: { model.selectedProcessing },
                            set: {
                                model.selectedProcessing = $0
                                model.controlsChanged(resetScale: true)
                            }
                        )) {
                            ForEach(ProcessingMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                .disabled(!canEditScanDisplay)

                InspectorSection(title: "Color Scale") {
                    HStack(spacing: 8) {
                        PaletteStrip(palette: model.selectedPalette, invert: model.invertPalette)
                            .frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.separator.opacity(0.9), lineWidth: 1))

                        Toggle("Invert", isOn: Binding(
                            get: { model.invertPalette },
                            set: {
                                model.invertPalette = $0
                                model.controlsChanged()
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .frame(width: 82, alignment: .trailing)
                    }

                    LabeledControl("Range") {
                        Picker("Range", selection: Binding(
                            get: { model.scalePreset },
                            set: { model.applyScalePreset($0) }
                        )) {
                            ForEach(ScalePreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .disabled(model.selectedStats == nil)

                    HStack(spacing: 8) {
                        ScaleField(title: "Min", value: Binding(
                            get: { model.scaleMin },
                            set: {
                                model.scaleMin = $0
                                if let lo = $0, let hi = model.scaleMax { model.updateScale(min: lo, max: hi) }
                            }
                        ))

                        ScaleField(title: "Max", value: Binding(
                            get: { model.scaleMax },
                            set: {
                                model.scaleMax = $0
                                if let lo = model.scaleMin, let hi = $0 { model.updateScale(min: lo, max: hi) }
                            }
                        ))
                    }

                    LabeledControl("Palette") {
                        Picker("Palette", selection: Binding(
                            get: { model.selectedPalette },
                            set: {
                                model.selectedPalette = $0
                                model.controlsChanged()
                            }
                        )) {
                            ForEach(PaletteName.allCases, id: \.self) { palette in
                                Text(palette.label).tag(palette)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                .disabled(!isSingle)

                InspectorSection(title: "Histogram") {
                    HStack(spacing: 8) {
                        LabeledControl("Bins") {
                            Picker("Bins", selection: $model.histogramBins) {
                                Text("64").tag(64)
                                Text("128").tag(128)
                                Text("256").tag(256)
                                Text("512").tag(512)
                                Text("1024").tag(1024)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 96)
                        }

                        Spacer()

                        if let stats = model.selectedStats {
                            StatLabel("n", "\(stats.count)")
                        }
                    }

                    HistogramView(model: model)
                        .frame(height: 260)

                    if let stats = model.selectedStats {
                        StatsGrid(stats: stats)
                    }
                }
                .disabled(!isSingle)
                .opacity(isSingle ? 1 : 0.35)

                Button {
                    model.exportPNG()
                } label: {
                    Label("Export PNG", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!isSingle || model.selectedImage == nil)

                InspectorSection(title: "Spectroscopy") {
                    if model.mode == .grid {
                        Toggle(
                            "Show spectrum cards in Grid",
                            isOn: Binding(
                                get: {
                                    model.showsGridSpectroscopyCards
                                },
                                set: { value in
                                    model
                                        .setGridSpectroscopyCardsVisible(
                                            value
                                        )
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .disabled(model.spectra.isEmpty)
                    } else if model.mode == .single {
                        Toggle(
                            "Show spectroscopy drawer",
                            isOn: Binding(
                                get: {
                                    model
                                        .singleSpectroscopyState
                                        .isExpanded
                                },
                                set: {
                                    model
                                        .setSingleSpectroscopyDrawerExpanded(
                                            $0
                                        )
                                }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    if !model.presentedSpectrumAxisRestoreIssues.isEmpty {
                        Label(
                            "\(model.presentedSpectrumAxisRestoreIssues.count) "
                                + "saved "
                                + "axis preference"
                                + (model.presentedSpectrumAxisRestoreIssues
                                    .count == 1
                                    ? "" : "s")
                                + " could not be restored; safe defaults "
                                + "are in use.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(
                            model.presentedSpectrumAxisRestoreIssues
                                .compactMap(\.errorDescription)
                                .joined(separator: "\n")
                        )
                    }

                    if let file = model.selectedFile {
                        let groups = model.spectrumGroups(for: file)
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                LabeledControl("X Channel") {
                                    Picker("X Channel", selection: Binding(
                                        get: { model.spectrumXAxis(for: group) },
                                        set: { model.setSpectrumXAxis($0, for: group) }
                                    )) {
                                        ForEach(group.availableColumns, id: \.self) { column in
                                            Text(column).tag(column)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .disabled(!model.canModifySpectrumAxes)
                                }

                                LabeledControl("Y Channel") {
                                    Picker("Y Channel", selection: Binding(
                                        get: { model.spectrumYAxis(for: group) },
                                        set: { model.setSpectrumYAxis($0, for: group) }
                                    )) {
                                        ForEach(group.availableColumns, id: \.self) { column in
                                            Text(column).tag(column)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .disabled(!model.canModifySpectrumAxes)
                                }
                            }
                        }

                        StatLabel("groups", "\(groups.count)")
                        StatLabel(
                            "visible spectra",
                            "\(model.spectraForMarkers(on: file).count)"
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private func formattedMetadataDate(
        _ date: Date
    ) -> String {
        date.formatted(
            date: .abbreviated,
            time: .standard
        )
    }

    private func formattedInspectorPair(
        _ pair: InspectorCoordinatePair?,
        separator: String,
        includesAxisNames: Bool = false
    ) -> String {
        guard let pair else { return "Unavailable" }
        let x = formattedInspectorLength(pair.x)
        let y = formattedInspectorLength(pair.y)
        if includesAxisNames {
            return "X \(x)\(separator)Y \(y)"
        }
        return "\(x)\(separator)\(y)"
    }

    private func formattedInspectorLength(
        _ meters: Double
    ) -> String {
        if meters == 0 {
            return "0 m"
        }
        return "\(compact(meters))m"
    }

    private func formattedInspectorAngle(
        _ angle: Double?
    ) -> String {
        guard let angle else { return "Unavailable" }
        return angle.formatted(
            .number.precision(
                .fractionLength(0...3)
            )
        ) + "°"
    }

    private func formattedInspectorChannel(
        _ presentation: InspectorMetadataPresentation
    ) -> String {
        guard !presentation.channelName.isEmpty else {
            return "Unavailable"
        }
        guard !presentation.channelUnit.isEmpty else {
            return presentation.channelName
        }
        return presentation.channelName
            + " · "
            + presentation.channelUnit
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator.opacity(0.8))
                .frame(height: 1)
                .offset(y: 9)
        }
    }
}

struct LabeledControl<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct StatLabel: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .font(.caption)
    }
}

private struct InspectorMetadataRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(
            alignment: .firstTextBaseline,
            spacing: 10
        ) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct StatsGrid: View {
    let stats: HistogramStats

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                StatLabel("min", compact(stats.min))
                Spacer()
                StatLabel("max", compact(stats.max))
            }
            HStack {
                StatLabel("mean", compact(stats.mean))
                Spacer()
                StatLabel("std", compact(stats.std))
            }
        }
        .padding(.top, 2)
    }
}

struct ScaleField: View {
    let title: String
    @Binding var value: Double?
    @State private var draftText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $draftText)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit {
                    commitDraft()
                }
        }
        .onAppear {
            draftText = value.map(compact) ?? ""
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            draftText = newValue.map(compact) ?? ""
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commitDraft()
            }
        }
    }

    private func commitDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = parseEngineeringDouble(trimmed) {
            value = parsed
            draftText = compact(parsed)
        } else {
            draftText = value.map(compact) ?? ""
        }
    }
}

