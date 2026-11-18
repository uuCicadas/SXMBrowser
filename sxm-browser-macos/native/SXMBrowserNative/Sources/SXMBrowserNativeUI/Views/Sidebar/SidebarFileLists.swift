import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let sxmBrowserTagID = UTType(
        exportedAs: TagDropPayload.typeIdentifier
    )
}

struct AllSidebarFileList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel

    private func scrollToSelection(with proxy: ScrollViewProxy) {
        guard let selectedID = model.selectedID else { return }
        DispatchQueue.main.async {
            withAnimation(BrowserMotion.navigation.animation(reduceMotion: reduceMotion)) {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.visibleFiles) { file in
                        SXMFileSidebarItem(model: model, file: file)
                        .id(file.id)
                    }

                    if !model.visibleUnassociatedSpectra.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        Label(
                            "Unassociated spectra",
                            systemImage: "link.badge.plus"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                        ForEach(model.visibleUnassociatedSpectra) {
                            spectrum in
                            SpectroscopySidebarRow(
                                model: model,
                                spectrum: spectrum
                            )
                            .padding(.leading, 8)
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollToSelection(with: proxy)
            }
            .onChange(of: model.selection) { _, _ in
                scrollToSelection(with: proxy)
            }
            .onChange(of: model.sortMode) { _, _ in
                scrollToSelection(with: proxy)
            }
            .onChange(of: model.sortAscending) { _, _ in
                scrollToSelection(with: proxy)
            }
        }
    }
}

struct TagSidebarFileList: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if model.tags.isEmpty {
                    Text("No tags")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ForEach(model.tags) { tag in
                        TagGroupView(model: model, tag: tag)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TagGroupView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AppModel
    let tag: DatasetTagV1
    @State private var isTagDropTargeted = false

    private var files: [SXMMetadata] {
        model.visibleFiles(forTagID: tag.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    model.toggleTagExpansion(tag.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(model.expandedTagIDs.contains(tag.id) ? 90 : 0))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    model.expandedTagIDs.contains(tag.id)
                        ? "Collapse \(tag.name)"
                        : "Expand \(tag.name)"
                )
                .accessibilityValue("\(files.count) files")

                Button {
                    model.selectTag(tag.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(
                            systemName:
                                model.activeTagID == tag.id
                                ? "tag.fill"
                                : "tag"
                        )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    Text(tag.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(files.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(model.activeTagID == tag.id ? AppTheme.selectedTile(for: colorScheme) : AppTheme.subtleFill.opacity(0.75))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isTagDropTargeted
                                    ? Color.accentColor
                                    : (
                                        model.activeTagID == tag.id
                                            ? Color.accentColor.opacity(0.9)
                                            : Color.clear
                                    ),
                                lineWidth: isTagDropTargeted ? 1.6 : 1
                            )
                    )
                    .browserMotion(.feedback, value: model.activeTagID == tag.id)
                    .browserMotion(.feedback, value: isTagDropTargeted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tag.name)
                .accessibilityValue(
                    [
                        "\(files.count) files",
                        model.activeTagID == tag.id
                            ? "Active tag"
                            : "Inactive tag",
                    ].joined(separator: ", ")
                )
                .accessibilityAddTraits(
                    model.activeTagID == tag.id
                        ? .isSelected
                        : []
                )
                .contextMenu {
                    Button {
                        model.promptToRenameTag(tag.id)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .disabled(!model.canModifyTags)

                    Divider()

                    Button(role: .destructive) {
                        model.deleteTag(id: tag.id)
                    } label: {
                        Label("Delete Tag", systemImage: "trash")
                    }
                    .disabled(!model.canModifyTags)
                }
                .onDrag {
                    tagItemProvider()
                }
                .onDrop(
                    of: [UTType.sxmBrowserTagID.identifier],
                    isTargeted: $isTagDropTargeted
                ) { providers in
                    handleTagDrop(providers)
                }
            }

            if model.expandedTagIDs.contains(tag.id) {
                if files.isEmpty {
                    Text("No files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 6)
                } else {
                    ForEach(files) { file in
                        SXMFileSidebarItem(model: model, file: file, tagContext: tag.id)
                    }
                }
            }
        }
        .browserMotion(.disclosure, value: model.expandedTagIDs.contains(tag.id))
    }

    private func tagItemProvider() -> NSItemProvider {
        guard model.canModifyTags else {
            return NSItemProvider()
        }
        let data = TagDropPayload(tagID: tag.id).encodedData
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.sxmBrowserTagID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func handleTagDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.canModifyTags,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(
                      UTType.sxmBrowserTagID.identifier
                  )
              }) else {
            return false
        }
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.sxmBrowserTagID.identifier
        ) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                guard model.canModifyTags else { return }
                model.moveTag(
                    fromDropData: data,
                    typeIdentifier: UTType.sxmBrowserTagID.identifier,
                    toTargetID: tag.id
                )
            }
        }
        return true
    }
}

struct SXMFileSidebarItem: View {
    let model: AppModel
    let file: SXMMetadata
    var tagContext: UUID? = nil
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                model.select(
                    file,
                    modifiers: NSEvent.modifierFlags,
                    tagContext: tagContext
                )
                model.requestFilenameSearchBlur()
            } label: {
                FileRow(
                    file: file,
                    isSelected: model.selectedIDs.contains(file.id),
                    isCurrent: model.selectedID == file.id,
                    spectrumCount: model.spectra(for: file).count,
                    isDropTargeted: isDropTargeted
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(file.filename)
            .accessibilityValue(
                [
                    model.selectedID == file.id
                        ? "Current file"
                        : (
                            model.selectedIDs.contains(file.id)
                                ? "Selected file"
                                : "Not selected"
                        ),
                    "\(file.pixels.width) by "
                        + "\(file.pixels.height) pixels",
                    file.defaultChannel.map {
                        "Channel \($0)"
                    },
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
            )
            .accessibilityAddTraits(
                model.selectedIDs.contains(file.id)
                    ? .isSelected
                    : []
            )
            .accessibilityHint(
                "Press to select. Use Command or Shift "
                    + "for multiple selection."
            )
            .contextMenu {
                FileContextMenu(model: model, file: file, tagContext: tagContext)
            }
            .onDrop(of: [UTType.plainText.identifier], isTargeted: $isDropTargeted) { providers in
                handleSpectrumDrop(providers)
            }
            .help("Drop spectra here to associate them with \(file.filename)")

            ForEach(model.spectra(for: file)) { spectrum in
                SpectroscopySidebarRow(
                    model: model,
                    spectrum: spectrum,
                    tagContext: tagContext
                )
                    .padding(.leading, 14)
            }
        }
    }

    private func handleSpectrumDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.canAssociateSpectra,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let token: String?
            if let data = item as? Data {
                token = String(data: data, encoding: .utf8)
            } else if let value = item as? String {
                token = value
            } else if let value = item as? NSString {
                token = value as String
            } else {
                token = nil
            }

            if let token {
                Task { @MainActor in
                    _ = model.associateSpectra(
                        fromDragToken: token,
                        to: file,
                        tagContext: tagContext
                    )
                }
            }
        }
        return true
    }
}

struct SpectroscopySidebarRow: View {
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast
    let model: AppModel
    let spectrum: SpectroscopyFile
    var tagContext: UUID? = nil

    var body: some View {
        HStack(spacing: 7) {
            Toggle(
                "Show \(spectrum.filename)",
                isOn: Binding(
                    get: {
                        model.isSpectrumVisible(spectrum)
                    },
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
                model.selectSpectrumRow(
                    spectrum,
                    modifiers: NSEvent.modifierFlags,
                    tagContext: tagContext
                )
            } label: {
                HStack(spacing: 7) {
                    SpectrumStyleGlyph(spectrum: spectrum)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(spectrum.filename)
                            .font(
                                .system(
                                    size: 11.5,
                                    weight: .medium
                                )
                            )
                            .lineLimit(1)
                        Text(spectrum.kind.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if isFocused {
                        Image(systemName: "scope")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spectrum.filename)
            .accessibilityValue(
                [
                    spectrumStyleDescription(for: spectrum),
                    isFocused
                        ? "Focused spectrum"
                        : (
                            isSelected
                                ? "Selected spectrum"
                                : "Spectrum"
                        ),
                ].joined(separator: ", ")
            )
            .accessibilityAddTraits(
                isSelected ? .isSelected : []
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(
                            colorSchemeContrast == .increased
                                ? 0.30
                                : 0.18
                        )
                        : Color.clear
                )
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width:
                            colorSchemeContrast == .increased
                            ? 5
                            : 3
                    )
                    .padding(.vertical, 4)
            }
        }
        .onDrag {
            NSItemProvider(object: model.dragToken(for: spectrum) as NSString)
        }
        .help("\(spectrum.filename) — Drag to associate with an SXM file")
    }

    private var isFocused: Bool {
        model.singleSpectroscopyState.focusedSpectrumID
            == spectrum.id
    }

    private var isSelected: Bool {
        model.sidebarSelectedSpectrumIDs.contains(
            spectrum.id
        )
    }
}

struct SpectrumStyleGlyph: View {
    @Environment(\.colorScheme) private var colorScheme
    let style: SpectrumVisualStyle
    let width: CGFloat
    let lineWidth: CGFloat

    init(
        spectrum: SpectroscopyFile,
        width: CGFloat = 32,
        lineWidth: CGFloat = 2.2
    ) {
        style = spectrumVisualStyle(for: spectrum)
        self.width = width
        self.lineWidth = lineWidth
    }

    init(
        style: SpectrumVisualStyle,
        width: CGFloat = 32,
        lineWidth: CGFloat = 2.2
    ) {
        self.style = style
        self.width = width
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(
                to: CGPoint(x: 1, y: size.height / 2)
            )
            path.addLine(
                to: CGPoint(
                    x: max(1, size.width - 1),
                    y: size.height / 2
                )
            )
            context.stroke(
                path,
                with: .color(Color.primary.opacity(colorScheme == .dark ? 0.35 : 0.22)),
                style: spectrumStrokeStyle(
                    style.pattern,
                    lineWidth: lineWidth + 1.8,
                    compact: true,
                    lineCap: .butt
                )
            )
            context.stroke(
                path,
                with: .color(spectrumColor(style, for: colorScheme)),
                style: spectrumStrokeStyle(
                    style.pattern,
                    lineWidth: lineWidth,
                    compact: true
                )
            )
        }
        .frame(
            width: width,
            height: max(10, lineWidth + 5)
        )
        .accessibilityHidden(true)
    }
}

