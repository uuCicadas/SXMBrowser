import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct InspectorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel
    @State private var isRawHeaderExpanded = false
    @State private var rawHeaderQuery = ""

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
                InspectorSection(title: "Acquisition & File") {
                    if let file = model.selectedFile,
                       let metadataPresentation {
                        acquisitionSummaryBlock(
                            file: file,
                            presentation: metadataPresentation
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

                InspectorSection(title: "Color Scale & Histogram") {
                    if isSingle {
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

                        HStack(spacing: 8) {
                            PaletteStrip(palette: model.selectedPalette, invert: model.invertPalette)
                                .frame(height: 24)

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
                            .frame(height: 240)

                        if let stats = model.selectedStats {
                            StatsGrid(stats: stats)
                        }

                        HStack(spacing: 8) {
                            Button("Auto Scale") {
                                model.applyScalePreset(.percentile)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.selectedStats == nil)

                            Spacer()

                            Button {
                                model.exportPNG()
                            } label: {
                                Label("Export PNG…", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.selectedImage == nil)
                            .help("Export pure sRGB PNG without overlays (Cmd+Shift+E)")
                        }
                        .padding(.top, 2)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "Switch to Single view to adjust color scale and inspect the channel histogram."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            if model.selectedFile != nil {
                                Button("Open Single View") {
                                    model.setMode(.single)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppTheme.elevatedCard(for: colorScheme))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                                )
                        )
                    }
                }

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

                        HStack {
                            StatLabel("groups", "\(groups.count)")
                            Spacer()
                            StatLabel(
                                "visible spectra",
                                "\(model.spectraForMarkers(on: file).count)"
                            )
                        }
                    }
                }

                if let metadataPresentation {
                    rawHeaderSection(metadataPresentation)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func acquisitionSummaryBlock(
        file: SXMMetadata,
        presentation: InspectorMetadataPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(file.filename)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(formattedInspectorChannel(presentation))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(AppTheme.subtleFill)
                        )
                        .foregroundStyle(.secondary)

                    if let isFeedbackActive = presentation.isFeedbackActive {
                        Text(isFeedbackActive ? "Feedback ON" : "Const. Height")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(
                                        (isFeedbackActive ? Color.green : Color.orange)
                                            .opacity(colorScheme == .dark ? 0.22 : 0.14)
                                    )
                            )
                            .foregroundStyle(isFeedbackActive ? Color.green : Color.orange)
                    }
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                AcquisitionMetricTile(
                    label: "Sample Bias",
                    value: presentation.sampleBiasVolts.map {
                        AppTheme.formattedSI($0, unit: "V")
                    } ?? "—"
                )
                AcquisitionMetricTile(
                    label: "Setpoint",
                    value: formattedSetpoint(presentation)
                )
                AcquisitionMetricTile(
                    label: "Scan Size",
                    value: AppTheme.formattedScanFootprint(
                        presentation.scanRangeMeters
                    ) ?? "—"
                )
                AcquisitionMetricTile(
                    label: "Temperature",
                    value: presentation.temperatureKelvin.map(
                        AppTheme.formattedTemperature
                    ) ?? "—"
                )
                AcquisitionMetricTile(
                    label: "Scan Speed",
                    value: presentation.scanSpeedMetersPerSecond.map {
                        AppTheme.formattedSI($0, unit: "m/s")
                    } ?? "—"
                )
                AcquisitionMetricTile(
                    label: "Acq. Time",
                    value: presentation.acquisitionSeconds.map(
                        AppTheme.formattedDuration
                    ) ?? "—"
                )
            }

            if let comment = presentation.comment {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Comment")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.elevatedCard(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                        )
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                InspectorMetadataRow(
                    "Dimensions",
                    "\(presentation.pixelWidth) × \(presentation.pixelHeight) px"
                )
                InspectorMetadataRow(
                    "Offset",
                    formattedInspectorPair(
                        presentation.scanOffsetMeters,
                        separator: " · ",
                        includesAxisNames: true
                    )
                )
                InspectorMetadataRow(
                    "Angle",
                    formattedInspectorAngle(presentation.scanAngleDegrees)
                )
                if let controller = presentation.feedbackControllerName {
                    InspectorMetadataRow("Controller", controller)
                }
                InspectorMetadataRow(
                    "Recorded",
                    presentation.recordedTime.map {
                        formattedMetadataDate($0)
                    } ?? "Not recorded"
                )
                InspectorMetadataRow(
                    "Modified",
                    formattedMetadataDate(presentation.modifiedTime)
                )
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func rawHeaderSection(
        _ presentation: InspectorMetadataPresentation
    ) -> some View {
        let filteredEntries = presentation.filteredHeaderEntries(
            matching: rawHeaderQuery
        )

        DisclosureGroup(
            "Raw Header (\(presentation.rawHeaderEntries.count))",
            isExpanded: $isRawHeaderExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Filter header keys or values…", text: $rawHeaderQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !rawHeaderQuery.isEmpty {
                        Button {
                            rawHeaderQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear raw header filter")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.subtleFill)
                )

                if filteredEntries.isEmpty {
                    Text("No matching header entries.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(filteredEntries) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.key)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(entry.value)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.elevatedCard(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                            )
                    )
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private func formattedSetpoint(
        _ presentation: InspectorMetadataPresentation
    ) -> String {
        if let value = presentation.setpointValue,
           let unit = presentation.setpointUnit,
           !unit.isEmpty {
            if ["A", "V", "Hz", "m"].contains(unit) {
                return AppTheme.formattedSI(value, unit: unit)
            }
            return "\(AppTheme.formattedSI(value, unit: "")) \(unit)"
        }
        if let value = presentation.setpointValue {
            return AppTheme.formattedSI(value, unit: "")
        }
        return presentation.setpointRawText ?? "—"
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
        AppTheme.formattedSI(meters, unit: "m")
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

private struct AcquisitionMetricTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppTheme.elevatedCard(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
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

