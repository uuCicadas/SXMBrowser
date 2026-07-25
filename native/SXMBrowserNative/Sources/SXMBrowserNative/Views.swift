import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let sxmBrowserTagID = UTType(
        exportedAs: TagDropPayload.typeIdentifier
    )
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false
    @State private var liveSidebarWidth: CGFloat
    @State private var liveInspectorWidth: CGFloat
    @State private var isResizingSplit = false

    init(model: AppModel) {
        self.model = model
        _liveSidebarWidth = State(initialValue: model.sidebarWidth)
        _liveInspectorWidth = State(initialValue: model.inspectorWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarView(model: model)
                    .frame(width: liveSidebarWidth)
                    .clipped()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SplitHandle(
                    width: $liveSidebarWidth,
                    range: AppModel.sidebarWidthRange,
                    defaultWidth: AppModel.defaultSidebarWidth,
                    edge: .leading,
                    onEditingChanged: { isResizingSplit = $0 },
                    onCommit: {
                        model.sidebarWidth = liveSidebarWidth
                        model.saveLayoutWidths()
                    }
                )
            }

            MainImageView(model: model)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

            if model.isInspectorVisible {
                SplitHandle(
                    width: $liveInspectorWidth,
                    range: AppModel.inspectorWidthRange,
                    defaultWidth: AppModel.defaultInspectorWidth,
                    edge: .trailing,
                    onEditingChanged: { isResizingSplit = $0 },
                    onCommit: {
                        model.inspectorWidth = liveInspectorWidth
                        model.saveLayoutWidths()
                    }
                )
                InspectorView(model: model)
                    .frame(width: liveInspectorWidth)
                    .clipped()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .transaction { transaction in
            if isResizingSplit {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .background(AppTheme.page)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.75), lineWidth: 3)
                    .padding(8)
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 740, maxHeight: .infinity, alignment: .leading)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.isSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .help(model.isSidebarVisible ? "Hide file list" : "Show file list")
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.resetLayout()
                    }
                } label: {
                    Image(systemName: "rectangle.3.group")
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help("Reset layout")

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.isInspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .help(model.isInspectorVisible ? "Hide inspector" : "Show inspector")
            }
        }
        .onAppear {
            liveSidebarWidth = model.sidebarWidth
            liveInspectorWidth = model.inspectorWidth
            model.openStartupFolder()
        }
        .onChange(of: model.sidebarWidth) { _, newValue in
            if !isResizingSplit {
                liveSidebarWidth = newValue
            }
        }
        .onChange(of: model.inspectorWidth) { _, newValue in
            if !isResizingSplit {
                liveInspectorWidth = newValue
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }

            if let url {
                Task { @MainActor in
                    model.openDroppedURL(url)
                }
            }
        }
        return true
    }
}

enum SplitEdge {
    case leading
    case trailing
}

struct SplitHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultWidth: CGFloat
    let edge: SplitEdge
    let onEditingChanged: (Bool) -> Void
    let onCommit: () -> Void
    @State private var startWidth: CGFloat?
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                Rectangle()
                    .fill(isDragging ? Color.accentColor.opacity(0.75) : AppTheme.separator.opacity(0.75))
                    .frame(width: isDragging ? 2 : 1)
                    .padding(.vertical, 10)
            }
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    width = defaultWidth
                }
                onCommit()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if startWidth == nil {
                            startWidth = width
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let origin = startWidth ?? width
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        let nextWidth = min(range.upperBound, max(range.lowerBound, origin + delta))
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            width = nextWidth
                        }
                    }
                    .onEnded { _ in
                        startWidth = nil
                        isDragging = false
                        onEditingChanged(false)
                        onCommit()
                    }
            )
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.chooseFolder()
                    } label: {
                        Label("Open", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut("o")

                    Text("\(model.files.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppTheme.subtleFill))

                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if !model.scanIssues.isEmpty {
                        Button {
                            model.showScanIssues()
                        } label: {
                            Label(
                                "\(model.scanIssues.count)",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .help("Show scan issues")
                    }
                }

                HStack(spacing: 6) {
                    FilledMenuButton(title: model.sortMode.label) {
                        ForEach(SortMode.allCases) { mode in
                            Button(mode.label) {
                                model.sortMode = mode
                            }
                        }
                    }

                    FilledMenuButton(title: model.sortAscending ? "Asc" : "Desc") {
                        Button("Asc") {
                            model.sortAscending = true
                        }
                        Button("Desc") {
                            model.sortAscending = false
                        }
                    }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                SearchField(text: Binding(
                    get: { model.filenameSearch },
                    set: { model.setFilenameSearch($0) }
                )) {
                    model.jumpToFilenameSearch()
                }

                HStack(spacing: 8) {
                    Picker("File grouping", selection: Binding(
                        get: { model.sidebarMode },
                        set: { model.setSidebarMode($0) }
                    )) {
                        ForEach(SidebarMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if model.sidebarMode == .tag {
                        Button {
                            model.promptForNewTag()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.canModifyTags)
                        .help("Create tag")

                        Menu {
                            Button {
                                model.sortTagsByName()
                            } label: {
                                Label(
                                    "Sort A–Z",
                                    systemImage: "textformat.abc"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!model.canModifyTags)
                        .help("Tag actions")
                    }
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.subtleFill.opacity(0.65))

                if model.isLoading {
                    ProgressView("Scanning...")
                } else if model.files.isEmpty
                            && model.unassociatedSpectrumIDs.isEmpty {
                    Text("No SXM files")
                        .foregroundStyle(.secondary)
                } else if model.sidebarMode == .all {
                    AllSidebarFileList(model: model)
                } else {
                    TagSidebarFileList(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 2)
        }
        .padding(12)
        .background(AppTheme.sidebar)
    }
}

struct AllSidebarFileList: View {
    @ObservedObject var model: AppModel

    private func scrollToSelection(with proxy: ScrollViewProxy) {
        guard let selectedID = model.selectedID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.18)) {
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
    @ObservedObject var model: AppModel

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
    @ObservedObject var model: AppModel
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
                    Image(systemName: model.expandedTagIDs.contains(tag.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    model.selectTag(tag.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
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
                }
                .buttonStyle(.plain)
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
    @ObservedObject var model: AppModel
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
            } label: {
                FileRow(
                    file: file,
                    isSelected: model.selectedIDs.contains(file.id),
                    isCurrent: model.selectedID == file.id,
                    isDropTargeted: isDropTargeted
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
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
    @ObservedObject var model: AppModel
    let spectrum: SpectroscopyFile
    var tagContext: UUID? = nil

    var body: some View {
        HStack(spacing: 7) {
            Toggle("", isOn: Binding(
                get: { model.isSpectrumVisible(spectrum) },
                set: { model.setSpectrum(spectrum, visible: $0) }
            ))
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 16)
            .disabled(!model.canModifySpectrumVisibility)

            VStack(alignment: .leading, spacing: 2) {
                Text(spectrum.filename)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text(spectrum.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(model.sidebarSelectedSpectrumIDs.contains(spectrum.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectSpectrumRow(
                spectrum,
                modifiers: NSEvent.modifierFlags,
                tagContext: tagContext
            )
        }
        .onDrag {
            NSItemProvider(object: model.dragToken(for: spectrum) as NSString)
        }
        .help("\(spectrum.filename) — Drag to associate with an SXM file")
    }
}

struct SearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search file name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.subtleFill.opacity(0.95))
        )
    }
}

struct FilledMenuButton<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.subtleFill.opacity(0.95))
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

struct FileRow: View {
    let file: SXMMetadata
    let isSelected: Bool
    let isCurrent: Bool
    var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.filename)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            HStack(spacing: 6) {
                Text("\(file.pixels.width)x\(file.pixels.height)")
                if let channel = file.defaultChannel {
                    Text(channel)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.95) : (isCurrent && isSelected ? Color.white.opacity(0.75) : Color.clear), lineWidth: isDropTargeted ? 1.6 : 1)
                .padding(1)
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}

struct FileContextMenu: View {
    @ObservedObject var model: AppModel
    let file: SXMMetadata
    var tagContext: UUID? = nil

    var body: some View {
        Button {
            model.openFilesForContext(containing: file, tagContext: tagContext)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }

        Button(role: .destructive) {
            model.deleteFilesForContext(containing: file, tagContext: tagContext)
        } label: {
            Label("Delete", systemImage: "trash")
        }

        Menu {
            if model.tags.isEmpty {
                Button("New Tag...") {
                    model.promptForNewTag(toContextContaining: file, tagContext: tagContext)
                }
            } else {
                ForEach(model.tags) { tag in
                    Button(tag.name) {
                        model.addTag(tag.id, toContextContaining: file, tagContext: tagContext)
                    }
                }
                Divider()
                Button("New Tag...") {
                    model.promptForNewTag(toContextContaining: file, tagContext: tagContext)
                }
            }
        } label: {
            Label("Add Tag", systemImage: "tag")
        }
        .disabled(!model.canModifyTags)

        Menu {
            let removableTags = model.removableTagsForContext(
                containing: file,
                tagContext: tagContext
            )
            if removableTags.isEmpty {
                Text("No Tags")
            } else {
                ForEach(removableTags) { tag in
                    Button(tag.name) {
                        model.removeTag(
                            tag.id,
                            fromContextContaining: file,
                            tagContext: tagContext
                        )
                    }
                }
            }
        } label: {
            Label("Remove Tag", systemImage: "tag.slash")
        }
        .disabled(!model.canModifyTags)

        Button {
            model.revealInFinderForContext(containing: file, tagContext: tagContext)
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
    }
}

struct MainImageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.selectedFile?.filename ?? "No file selected")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(model.selectedPositionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AppTheme.subtleFill))

                Spacer()

                if model.mode == .grid {
                    GridDensityControl(model: model)
                }

                Button {
                    model.toggleSpectraVisibility()
                } label: {
                    Image(systemName: model.areSpectraVisible ? "waveform.path.ecg.rectangle" : "eye.slash")
                }
                .disabled(model.spectra.isEmpty)
                .help(model.areSpectraVisible ? "Hide spectroscopy plots" : "Show spectroscopy plots")

                Picker("Mode", selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    ForEach(BrowserMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 158)

                Button {
                    model.stepSelection(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canStepSelection(by: -1))

                Button {
                    model.stepSelection(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canStepSelection(by: 1))

                Button(role: .destructive) {
                    model.deleteSelectedFiles()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!model.canDeleteSelection)
                .help(model.selectedCount <= 1 ? "Delete selected file" : "Delete \(model.selectedCount) selected files")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(AppTheme.toolbar)

            Divider()

            if model.mode == .grid {
                GridBrowserView(model: model)
            } else {
                SingleImageView(model: model)
            }
        }
        .background(AppTheme.page)
        .overlay {
            KeyboardArrowOverlay { direction in
                model.moveSelectionForArrow(direction)
            }
        }
        .onMoveCommand { direction in
            model.moveSelectionForArrow(direction)
        }
    }
}

struct KeyboardArrowOverlay: NSViewRepresentable {
    let onArrow: (MoveCommandDirection) -> Void

    func makeNSView(context: Context) -> KeyboardArrowCatcherView {
        let view = KeyboardArrowCatcherView()
        view.onArrow = onArrow
        return view
    }

    func updateNSView(_ nsView: KeyboardArrowCatcherView, context: Context) {
        nsView.onArrow = onArrow
    }
}

@MainActor
final class KeyboardArrowCatcherView: NSView {
    var onArrow: ((MoveCommandDirection) -> Void)?
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installEventMonitor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isEventForThisWindow(event), !isTextInputFocused, hasNoCommandModifiers(event) else { return false }
        let direction: MoveCommandDirection?
        switch event.keyCode {
        case 123:
            direction = .left
        case 124:
            direction = .right
        case 125:
            direction = .down
        case 126:
            direction = .up
        default:
            direction = nil
        }

        guard let direction else { return false }
        onArrow?(direction)
        return true
    }

    private func isEventForThisWindow(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        return event.window === window || NSApp.keyWindow === window
    }

    private func hasNoCommandModifiers(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        return modifiers.isEmpty
    }

    private var isTextInputFocused: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        if firstResponder is NSTextView {
            return true
        }
        if firstResponder is NSTextField {
            return true
        }
        return false
    }

}

struct GridDensityControl: View {
    @ObservedObject var model: AppModel

    private var columnsBinding: Binding<Double> {
        Binding(
            get: { Double(model.gridColumns) },
            set: { model.gridColumns = min(8, max(2, Int($0.rounded()))) }
        )
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Slider(value: columnsBinding, in: 2...8, step: 1)
                .frame(width: 104)

            Text("\(model.gridColumns)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(AppTheme.subtleFill.opacity(0.9))
        )
        .help("Images per row")
    }
}

struct GridBrowserView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            AppTheme.gridStage(for: colorScheme)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.visibleDisplayItems) { item in
                            switch item {
                            case .sxm(let file):
                                ThumbnailCard(model: model, file: file)
                                    .id(item.id)
                            case .spectroscopy(let group):
                                SpectroscopyPlotCard(model: model, group: group)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(18)
                }
                .background(AppTheme.gridStage(for: colorScheme))
                .scrollContentBackground(.hidden)
                .onAppear {
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
                .onChange(of: model.gridColumns) { _, _ in
                    scrollToSelection(with: proxy)
                }
                .onChange(of: model.activeTagID) { _, _ in
                    scrollToSelection(with: proxy)
                }
            }
        }
        .background(AppTheme.gridStage(for: colorScheme))
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 96), spacing: 14), count: model.gridColumns)
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

struct ThumbnailCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let file: SXMMetadata
    @State private var image: NSImage?

    private var isSelected: Bool {
        model.selectedIDs.contains(file.id)
    }

    private var isCurrent: Bool {
        model.selectedID == file.id
    }

    private var thumbnailTaskID: String {
        if isCurrent {
            return [
                file.id.uuidString,
                "selected",
                model.selectedChannel,
                model.selectedDirection.rawValue,
                model.selectedProcessing.rawValue,
                model.selectedPalette.rawValue,
                String(model.invertPalette)
            ].joined(separator: "|")
        }
        return "\(file.id.uuidString)|default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(AppTheme.imageWell(for: colorScheme))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(6)
                    SpectroscopyMarkerLayer(model: model, file: file)
                        .padding(6)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(file.filename)
                .font(.caption)
                .lineLimit(1)

            HStack {
                Text(file.defaultChannel ?? "-")
                    .lineLimit(1)
                Spacer()
                Text("\(file.pixels.width)x\(file.pixels.height)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AppTheme.selectedTile(for: colorScheme) : AppTheme.cardSurface(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(isCurrent ? 0.95 : 0.65) : AppTheme.tileBorder(for: colorScheme), lineWidth: isCurrent ? 1.8 : (isSelected ? 1.3 : 1))
        )
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.10) : Color.black.opacity(0.045),
            radius: isSelected ? 8 : 5,
            x: 0,
            y: isSelected ? 3 : 2
        )
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        model.select(file)
                        model.setMode(.single)
                    case .second:
                        model.select(file, modifiers: NSEvent.modifierFlags)
                    }
                }
        )
        .contextMenu {
            FileContextMenu(model: model, file: file)
        }
        .task(id: thumbnailTaskID) {
            image = await model.thumbnail(for: file, usingSelection: isCurrent)
        }
    }
}

struct SpectroscopyMarkerLayer: View {
    @ObservedObject var model: AppModel
    let file: SXMMetadata

    var body: some View {
        GeometryReader { proxy in
            let rect = imageRect(in: proxy.size)
            ForEach(model.spectraForMarkers(on: file)) { spectrum in
                if let point = model.normalizedMarkerPosition(for: spectrum, on: file) {
                    let center = CGPoint(
                        x: rect.minX + point.x * rect.width,
                        y: rect.minY + point.y * rect.height
                    )
                    MeasurementMarker(color: spectrumColor(for: spectrum))
                        .position(center)
                }
            }
        }
        .allowsHitTesting(false)
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
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.92))
                .frame(width: 8, height: 8)
            Circle()
                .stroke(Color.white.opacity(0.95), lineWidth: 1.2)
                .frame(width: 11, height: 11)
            Circle()
                .stroke(Color.black.opacity(0.55), lineWidth: 0.8)
                .frame(width: 13, height: 13)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }
}

struct SpectroscopyPlotCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let group: SpectroscopyGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpectroscopyPlotView(
                group: group,
                xColumn: model.spectrumXAxis(for: group),
                yColumn: model.spectrumYAxis(for: group)
            )
                .id("\(group.renderID)|\(model.spectrumXAxis(for: group))|\(model.spectrumYAxis(for: group))")
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(group.title)
                .font(.caption)
                .lineLimit(1)

            HStack {
                Text(group.kind.label)
                    .lineLimit(1)
                Spacer()
                Text(group.curveCountText)
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
    let group: SpectroscopyGroup
    let xColumn: String
    let yColumn: String

    private let inset = EdgeInsets(top: 20, leading: 50, bottom: 36, trailing: 14)

    var body: some View {
        Canvas { context, size in
            drawPlot(context: &context, size: size)
        }
        .background(Color.white)
    }

    private func drawPlot(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(
            x: inset.leading,
            y: inset.top,
            width: max(1, size.width - inset.leading - inset.trailing),
            height: max(1, size.height - inset.top - inset.bottom)
        )

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
        drawFrame(context: &context, plot: plot)

        let ranges = dataRanges()
        drawTicks(context: &context, plot: plot, ranges: ranges)
        drawCurves(context: &context, plot: plot, ranges: ranges)

        context.draw(
            Text(group.kind.label).font(.custom("Arial", size: 12).weight(.semibold)).foregroundColor(.black),
            at: CGPoint(x: plot.minX + 7, y: plot.minY + 7),
            anchor: .topLeading
        )
        context.draw(
            Text(xColumn).font(.custom("Arial", size: 9)).foregroundColor(.black.opacity(0.82)),
            at: CGPoint(x: plot.midX, y: size.height - 12),
            anchor: .center
        )
        var yLabelContext = context
        yLabelContext.translateBy(x: 10, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(
            Text(yColumn).font(.custom("Arial", size: 9)).foregroundColor(.black.opacity(0.82)),
            at: .zero,
            anchor: .center
        )
    }

    private func drawFrame(context: inout GraphicsContext, plot: CGRect) {
        context.stroke(Path(plot), with: .color(.black), lineWidth: 1)
    }

    private func drawTicks(context: inout GraphicsContext, plot: CGRect, ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)) {
        let tickLength: CGFloat = 5
        for i in 0...4 {
            let fraction = CGFloat(i) / 4
            let x = plot.minX + plot.width * fraction
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: plot.maxY))
            tick.addLine(to: CGPoint(x: x, y: plot.maxY - tickLength))
            context.stroke(tick, with: .color(.black), lineWidth: 0.8)

            let value = ranges.xMin + Double(fraction) * (ranges.xMax - ranges.xMin)
            context.draw(
                Text(compact(value)).font(.custom("Arial", size: 8)).foregroundColor(.black),
                at: CGPoint(x: x, y: plot.maxY + 8),
                anchor: .top
            )
        }

        for i in 0...4 {
            let fraction = CGFloat(i) / 4
            let y = plot.maxY - plot.height * fraction
            var tick = Path()
            tick.move(to: CGPoint(x: plot.minX, y: y))
            tick.addLine(to: CGPoint(x: plot.minX + tickLength, y: y))
            context.stroke(tick, with: .color(.black), lineWidth: 0.8)

            let value = ranges.yMin + Double(fraction) * (ranges.yMax - ranges.yMin)
            context.draw(
                Text(compact(value)).font(.custom("Arial", size: 8)).foregroundColor(.black),
                at: CGPoint(x: plot.minX - 5, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawCurves(context: inout GraphicsContext, plot: CGRect, ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)) {
        for spectrum in group.spectra {
            guard let points = group.points(
                for: spectrum,
                xColumn: xColumn,
                yColumn: yColumn
            ) else {
                continue
            }
            var path = Path()
            var didMove = false
            for pointValue in points where pointValue.x.isFinite && pointValue.y.isFinite {
                let xValue = pointValue.x
                let yValue = pointValue.y
                let x = plot.minX + CGFloat((xValue - ranges.xMin) / max(1e-30, ranges.xMax - ranges.xMin)) * plot.width
                let y = plot.maxY - CGFloat((yValue - ranges.yMin) / max(1e-30, ranges.yMax - ranges.yMin)) * plot.height
                let point = CGPoint(x: x, y: y)
                if didMove {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    didMove = true
                }
            }
            context.stroke(path, with: .color(spectrumColor(for: spectrum)), lineWidth: 1.35)
        }
    }

    private func dataRanges() -> (xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        let points = group.spectra.flatMap {
            group.points(
                for: $0,
                xColumn: xColumn,
                yColumn: yColumn
            ) ?? []
        }
        let xs = points.map { $0.x }.filter(\.isFinite)
        let ys = points.map { $0.y }.filter(\.isFinite)
        let xMin = xs.min() ?? 0
        var xMax = xs.max() ?? 1
        var yMin = ys.min() ?? 0
        var yMax = ys.max() ?? 1
        if xMax <= xMin { xMax = xMin + 1 }
        if yMax <= yMin { yMax = yMin + 1 }
        let yPad = (yMax - yMin) * 0.06
        yMin -= yPad
        yMax += yPad
        return (xMin, xMax, yMin, yMax)
    }
}

func spectrumColor(for spectrum: SpectroscopyFile) -> Color {
    spectrumColor(spectrum.colorIndex)
}

func spectrumColor(_ index: Int) -> Color {
    let colors: [Color] = [
        Color(red: 0.10, green: 0.33, blue: 0.82),
        Color(red: 0.82, green: 0.20, blue: 0.16),
        Color(red: 0.10, green: 0.58, blue: 0.25),
        Color(red: 0.68, green: 0.30, blue: 0.86),
        Color(red: 0.90, green: 0.55, blue: 0.08),
        Color(red: 0.06, green: 0.56, blue: 0.62),
        Color(red: 0.76, green: 0.12, blue: 0.42),
        Color(red: 0.24, green: 0.24, blue: 0.24),
    ]
    return colors[index % colors.count]
}


struct SingleImageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.stage
                if let frame = model.renderedFrame,
                   frame.request.fileID == model.selectedID,
                   let file = model.files.first(where: { $0.id == frame.request.fileID }) {
                    Image(nsImage: frame.image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: proxy.size.width - 36, height: proxy.size.height - 36)
                        .overlay {
                            SpectroscopyMarkerLayer(model: model, file: file)
                        }
                } else {
                    ProgressView()
                }
            }
        }
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var isSingle: Bool { model.mode == .single && model.selectedFile != nil }
    var canEditScanDisplay: Bool { model.selectedFile != nil && !model.files.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                    Toggle("Show plots", isOn: Binding(
                        get: { model.areSpectraVisible },
                        set: { _ in model.toggleSpectraVisibility() }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.spectra.isEmpty)

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
                                }
                            }
                        }

                        StatLabel("plots", "\(groups.count)")
                        StatLabel("points", "\(model.spectraForMarkers(on: file).count)")
                    }
                }
            }
            .padding(12)
        }
        .background(AppTheme.sidebar)
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
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: {
                    if text.isEmpty, let value {
                        return compact(value)
                    }
                    return text
                },
                set: { newValue in
                    text = newValue
                    value = Double(newValue)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        }
        .onChange(of: value) { _, newValue in
            text = newValue.map(compact) ?? ""
        }
    }
}

struct HistogramView: View {
    @ObservedObject var model: AppModel
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

struct PaletteStrip: View {
    let palette: PaletteName
    let invert: Bool

    var body: some View {
        Canvas { context, size in
            let stops = PaletteStore.shared.stops(for: palette)
            let steps = max(2, Int(size.width))
            for idx in 0..<steps {
                let t = Double(idx) / Double(steps - 1)
                let sample = invert ? 1 - t : t
                let color = paletteColor(stops: stops, at: sample)
                let rect = CGRect(x: CGFloat(idx), y: 0, width: 1.5, height: size.height)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func paletteColor(stops: [PaletteStop], at value: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return .gray }
        if value <= first.position { return Color(red: first.r, green: first.g, blue: first.b) }
        if value >= last.position { return Color(red: last.r, green: last.g, blue: last.b) }
        for idx in 0..<(stops.count - 1) {
            let a = stops[idx]
            let b = stops[idx + 1]
            if value >= a.position && value <= b.position {
                let span = max(1e-12, b.position - a.position)
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

enum AppTheme {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let control = Color(nsColor: .controlColor)
    static let toolbar = Color(nsColor: .windowBackgroundColor)
    static let stage = Color(nsColor: .underPageBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.16)
    static let histogramFill = Color(red: 0.86, green: 0.70, blue: 0.32)
    static let histogramStroke = Color(red: 0.98, green: 0.80, blue: 0.34)
    static let histogramHandle = Color(red: 0.30, green: 0.68, blue: 0.94)

    static func gridStage(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.100, green: 0.105, blue: 0.112)
            : Color(red: 0.945, green: 0.952, blue: 0.958)
    }

    static func cardSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.155, green: 0.162, blue: 0.172)
            : Color(red: 0.985, green: 0.987, blue: 0.990)
    }

    static func selectedTile(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.122, green: 0.205, blue: 0.335)
            : Color(red: 0.905, green: 0.940, blue: 0.990)
    }

    static func imageWell(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.090, green: 0.096, blue: 0.104)
            : Color(red: 0.928, green: 0.936, blue: 0.944)
    }

    static func tileBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.11)
            : Color.black.opacity(0.08)
    }
}

func compact(_ value: Double) -> String {
    if value == 0 { return "0" }
    let absValue = abs(value)

    let prefixes: [(Double, String)] = [
        (1e9, "G"),
        (1e6, "M"),
        (1e3, "k"),
        (1.0, ""),
        (1e-3, "m"),
        (1e-6, "u"),
        (1e-9, "n"),
        (1e-12, "p"),
    ]

    if let prefix = prefixes.first(where: { absValue >= $0.0 }) {
        let scaled = value / prefix.0
        let magnitude = abs(scaled)
        let format: String
        if magnitude >= 100 {
            format = "%.0f%@"
        } else if magnitude >= 10 {
            format = "%.2g%@"
        } else {
            format = "%.3g%@"
        }
        return String(format: format, scaled, prefix.1)
    }

    return String(format: "%.3e", value)
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
