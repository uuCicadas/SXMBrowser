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
        GeometryReader { proxy in
            let layout = ResponsivePaneLayout(
                containerWidth: Double(proxy.size.width)
            )

            VStack(spacing: 0) {
                if let banner = model.noticePresentation.banner {
                    UserNoticeBanner(
                        notice: banner,
                        onAction: model.performNoticeAction,
                        onDismiss: {
                            model.dismissNoticeBanner(id: banner.id)
                        }
                    )
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                }

                if model.shouldPresentMetadataWarning {
                    MetadataWarningStrip(model: model)
                        .transition(
                            .move(edge: .top).combined(with: .opacity)
                        )
                }

                inlineBrowser(layout: layout)
                    .overlay(alignment: .leading) {
                        if model.isSidebarVisible,
                           layout.sidebarPlacement == .overlay {
                            floatingSidebar
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if model.isInspectorVisible,
                           layout.inspectorPlacement == .overlay {
                            floatingInspector
                        }
                    }
                    .transaction { transaction in
                        if isResizingSplit {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
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
        .overlay(alignment: .bottom) {
            if let toast = model.noticePresentation.toast {
                UserNoticeToast(
                    notice: toast,
                    onDismiss: {
                        model.dismissNoticeToast(id: toast.id)
                    }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .transition(
                    .move(edge: .bottom).combined(with: .opacity)
                )
                .zIndex(10)
            }
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: model.noticePresentation
        )
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
        .sheet(
            isPresented: Binding(
                get: { model.metadataImportWorkflow != nil },
                set: { isPresented in
                    if !isPresented {
                        model.dismissMetadataImport()
                    }
                }
            )
        ) {
            MetadataImportPreviewSheet(model: model)
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

    private func inlineBrowser(
        layout: ResponsivePaneLayout
    ) -> some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible,
               layout.sidebarPlacement == .inline {
                SidebarView(model: model)
                    .frame(width: liveSidebarWidth)
                    .clipped()
                    .transition(
                        .move(edge: .leading).combined(with: .opacity)
                    )
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
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )

            if model.isInspectorVisible,
               layout.inspectorPlacement == .inline {
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
                    .transition(
                        .move(edge: .trailing).combined(with: .opacity)
                    )
            }
        }
    }

    private var floatingSidebar: some View {
        SidebarView(model: model)
            .frame(width: liveSidebarWidth)
            .frame(maxHeight: .infinity)
            .background(AppTheme.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 18, x: 4, y: 0)
            .padding(12)
            .transition(
                .move(edge: .leading).combined(with: .opacity)
            )
            .zIndex(2)
    }

    private var floatingInspector: some View {
        InspectorView(model: model)
            .frame(width: liveInspectorWidth)
            .frame(maxHeight: .infinity)
            .background(AppTheme.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppTheme.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 18, x: -4, y: 0)
            .padding(12)
            .transition(
                .move(edge: .trailing).combined(with: .opacity)
            )
            .zIndex(3)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.canOpenFolder else {
            return false
        }
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

private struct UserNoticeBanner: View {
    let notice: UserNotice
    let onAction: (NoticeAction) -> Void
    let onDismiss: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: notice.severity.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notice.title)
            .accessibilityValue(notice.message)

            ForEach(notice.actions, id: \.self) { action in
                Button(action.label) {
                    onAction(action)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(action.helpText)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Dismiss notification")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(AppTheme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: contrast == .increased ? 5 : 4)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: contrast == .increased ? 2 : 1)
                .accessibilityHidden(true)
        }
    }

    private var accent: Color {
        if contrast == .increased {
            return .primary
        }
        return notice.severity.accentColor
    }
}

private struct UserNoticeToast: View {
    let notice: UserNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: notice.severity.symbolName)
                .foregroundStyle(notice.severity.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss notification")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(AppTheme.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }
}

private extension NoticeSeverity {
    var symbolName: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private extension NoticeAction {
    var label: String {
        switch self {
        case .retryFolder, .retryRender:
            "Retry"
        case .showInFinder:
            "Show in Finder"
        case .showScanIssues, .showMetadataDetails:
            "Details"
        }
    }

    var helpText: String {
        switch self {
        case .retryFolder:
            "Scan the current folder again"
        case .retryRender:
            "Render the selected file again"
        case .showInFinder:
            "Reveal the selected file in Finder"
        case .showScanIssues:
            "Review skipped or partially read files"
        case .showMetadataDetails:
            "Review metadata issues"
        }
    }
}

private struct MetadataWarningStrip: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(warningAccent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Metadata Features Are Limited")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(model.metadataWarningSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Metadata warning")
            .accessibilityValue(model.metadataWarningSummary)

            Button("Details") {
                model.showMetadataWarningDetails()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show every metadata warning")
            .accessibilityHint(
                "Opens a list of all metadata issues for this dataset."
            )

            Button("Retry") {
                model.retryMetadataWarning()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canRetryMetadataWarning)
            .help(
                model.canRetryMetadataWarning
                    ? "Retry metadata setup for the current folder"
                    : "Retry is available after the current operation finishes"
            )
            .accessibilityHint(
                "Retries metadata setup without changing the selected file."
            )

            Button {
                model.dismissMetadataWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Dismiss metadata warning")
            .accessibilityLabel("Dismiss metadata warning")
            .accessibilityHint(
                "Hides this warning until a new metadata issue is reported."
            )
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(AppTheme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(warningAccent)
                .frame(width: contrast == .increased ? 5 : 4)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: contrast == .increased ? 2 : 1)
                .accessibilityHidden(true)
        }
    }

    private var warningAccent: Color {
        contrast == .increased ? .primary : .orange
    }
}

private struct MetadataImportPreviewSheet: View {
    @ObservedObject var model: AppModel

    private var workflow: MetadataImportWorkflow? {
        model.metadataImportWorkflow
    }

    private var isApplying: Bool {
        guard let workflow else { return false }
        if case .applying = workflow.phase {
            return true
        }
        return false
    }

    var body: some View {
        Group {
            if let workflow {
                VStack(alignment: .leading, spacing: 16) {
                    header(for: workflow)
                    Divider()
                    workflowContent(workflow)
                    Divider()
                    buttons(for: workflow)
                }
                .padding(22)
            } else {
                EmptyView()
            }
        }
        .frame(width: 680, height: 620)
        .background(AppTheme.page)
        .interactiveDismissDisabled(isApplying)
    }

    @ViewBuilder
    private func header(
        for workflow: MetadataImportWorkflow
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon(for: workflow.phase))
                .font(.title2)
                .foregroundStyle(headerColor(for: workflow.phase))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle(for: workflow))
                    .font(.title2.weight(.semibold))
                Text(workflow.sourceFilename)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func workflowContent(
        _ workflow: MetadataImportWorkflow
    ) -> some View {
        switch workflow.phase {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Reading and validating the metadata file…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .preview:
            if let plan = workflow.plan {
                planReport(
                    plan,
                    noChangesMessage:
                        plan.hasChanges ? nil : "Nothing to import"
                )
            }

        case .applying:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Applying and verifying metadata…")
                    .font(.body)
                Text(
                    "The preview remains locked until the metadata store "
                        + "has been written and read back successfully."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(message)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .font(.body)
                if let plan = workflow.plan {
                    planReport(plan, noChangesMessage: nil)
                } else {
                    Spacer()
                }
            }

        case .completed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.green)
                if let plan = workflow.plan {
                    planReport(plan, noChangesMessage: nil)
                } else {
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func planReport(
        _ plan: DatasetMetadataImportPlan,
        noChangesMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let noChangesMessage {
                Label(
                    noChangesMessage,
                    systemImage: "checkmark.circle"
                )
                .font(.headline)
            }

            MetadataImportSummaryView(summary: plan.summary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let actions = actionDescriptions(for: plan)
                    if !actions.isEmpty {
                        MetadataImportDetailSection(
                            title: "Planned changes",
                            icon: "arrow.down.doc",
                            lines: actions
                        )
                    }

                    let resolved = plan.issues
                        .filter(\.isResolvedConflict)
                        .map(issueDescription)
                    if !resolved.isEmpty {
                        MetadataImportDetailSection(
                            title: "Resolved conflicts",
                            icon: "arrow.triangle.branch",
                            lines: resolved
                        )
                    }

                    let skipped = plan.issues
                        .filter(\.isSkippedItem)
                        .map(issueDescription)
                    if !skipped.isEmpty {
                        MetadataImportDetailSection(
                            title: "Skipped items",
                            icon: "forward.end",
                            lines: skipped
                        )
                    }

                    let unresolved = plan.issues
                        .filter(\.isUnresolvedConflict)
                        .map(issueDescription)
                    if !unresolved.isEmpty {
                        MetadataImportDetailSection(
                            title: "Unresolved issues",
                            icon: "exclamationmark.triangle",
                            lines: unresolved
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func buttons(
        for workflow: MetadataImportWorkflow
    ) -> some View {
        HStack {
            Spacer()
            switch workflow.phase {
            case .loading:
                Button("Cancel") {
                    model.dismissMetadataImport()
                }
                .keyboardShortcut(.cancelAction)

            case .preview:
                Button(
                    workflow.plan?.hasChanges == true
                        ? "Cancel"
                        : "Close"
                ) {
                    model.dismissMetadataImport()
                }
                .keyboardShortcut(.cancelAction)

                if workflow.plan?.hasChanges == true {
                    Button("Import") {
                        model.confirmMetadataImport()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workflow.plan?.canApply != true)
                }

            case .applying:
                ProgressView()
                    .controlSize(.small)
                Text("Applying…")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .failed:
                Button("Close") {
                    model.dismissMetadataImport()
                }
                .keyboardShortcut(.cancelAction)

                if workflow.plan?.hasChanges == true,
                   workflow.plan?.canApply == true {
                    Button("Try Again") {
                        model.confirmMetadataImport()
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .completed:
                Button("Close") {
                    model.dismissMetadataImport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func headerTitle(
        for workflow: MetadataImportWorkflow
    ) -> String {
        switch workflow.phase {
        case .loading:
            "Preparing Metadata Import"
        case .preview:
            workflow.plan?.hasChanges == true
                ? "Review Metadata Import"
                : "Nothing to Import"
        case .applying:
            "Importing Metadata"
        case .failed:
            "Metadata Import Failed"
        case .completed:
            "Metadata Import Complete"
        }
    }

    private func headerIcon(
        for phase: MetadataImportWorkflowPhase
    ) -> String {
        switch phase {
        case .loading, .applying:
            "arrow.triangle.2.circlepath"
        case .preview:
            "doc.text.magnifyingglass"
        case .failed:
            "xmark.octagon.fill"
        case .completed:
            "checkmark.circle.fill"
        }
    }

    private func headerColor(
        for phase: MetadataImportWorkflowPhase
    ) -> Color {
        switch phase {
        case .failed:
            .red
        case .completed:
            .green
        case .loading, .preview, .applying:
            .accentColor
        }
    }

    private func actionDescriptions(
        for plan: DatasetMetadataImportPlan
    ) -> [String] {
        let tagNames = Dictionary(
            uniqueKeysWithValues: plan.preview.tags.map {
                ($0.id, $0.name)
            }
        )
        return plan.actions.map { action in
            switch action {
            case .addTag(let tag):
                let count = tag.sxmPaths.count
                return
                    "Add tag “\(tag.name)” with \(count) file"
                    + (count == 1 ? "." : "s.")

            case .mergeTag(_, let destinationTagID, let paths):
                let name =
                    tagNames[destinationTagID]
                    ?? shortID(destinationTagID)
                return
                    "Add \(paths.count) file"
                    + (paths.count == 1 ? "" : "s")
                    + " to tag “\(name)”."

            case .renameTag(_, let from, let to):
                return "Rename tag “\(from)” to “\(to)”."

            case .addManualAssociation(let association):
                return
                    "Associate \(association.datPath.rawValue) with "
                    + "\(association.sxmPath.rawValue)."

            case .replaceManualAssociation(
                let datPath,
                let from,
                let to
            ):
                return
                    "Change \(datPath.rawValue) association from "
                    + "\(from.rawValue) to \(to.rawValue)."

            case .hideDAT(let path):
                return "Hide spectrum \(path.rawValue)."

            case .addAxisPreference(let preference):
                return
                    "Set \(axisGroupDescription(preference.key)) axes to "
                    + "\(preference.selection.xColumn) / "
                    + "\(preference.selection.yColumn)."

            case .replaceAxisPreference(
                let key,
                let from,
                let to
            ):
                return
                    "Change \(axisGroupDescription(key)) axes from "
                    + "\(from.xColumn) / \(from.yColumn) to "
                    + "\(to.xColumn) / \(to.yColumn)."
            }
        }
    }

    private func issueDescription(
        _ issue: DatasetMetadataImportIssue
    ) -> String {
        switch issue {
        case .missingTagMember(let tagID, let sxmPath):
            return
                "Tag \(shortID(tagID)) references missing file "
                + "\(sxmPath.rawValue)."

        case .tagIdentityConflict(
            let kind,
            _,
            let importedName,
            _,
            _,
            let resolution
        ):
            return
                "\(tagConflictDescription(kind)) for tag "
                + "“\(importedName)”; "
                + "\(resolutionDescription(resolution))."

        case .associationDATMissing(let datPath):
            return
                "Association skipped because \(datPath.rawValue) "
                + "is not in this dataset."

        case .associationSXMMissing(let datPath, let sxmPath):
            return
                "Association for \(datPath.rawValue) skipped because "
                + "\(sxmPath.rawValue) is not in this dataset."

        case .associationConflict(
            let datPath,
            let destination,
            let imported,
            let resolution
        ):
            return
                "\(datPath.rawValue) is associated with "
                + "\(destination.rawValue) here and "
                + "\(imported.rawValue) in the import; "
                + "\(resolutionDescription(resolution))."

        case .hiddenDATMissing(let datPath):
            return
                "Hidden spectrum \(datPath.rawValue) is not in "
                + "this dataset."

        case .axisGroupUnavailable(let key, let fingerprints):
            let available = fingerprints.isEmpty
                ? "no compatible schemas"
                : fingerprints.joined(separator: ", ")
            return
                "\(axisGroupDescription(key)) is unavailable "
                + "(\(available))."

        case .axisExperimentAmbiguous(let key, let identities):
            return
                "\(axisGroupDescription(key)) is a legacy preference that "
                + "matches multiple experiments: "
                + identities.joined(separator: ", ")
                + ". It was not imported."

        case .axisColumnMissing(let key, let axis, let column):
            return
                "\(axisLabel(axis)) column “\(column)” is missing for "
                + "\(axisGroupDescription(key))."

        case .axisColumnAmbiguous(
            let key,
            let axis,
            let column,
            let matches
        ):
            return
                "\(axisLabel(axis)) column “\(column)” is ambiguous for "
                + "\(axisGroupDescription(key)): "
                + matches.joined(separator: ", ")
                + "."

        case .axisConflict(
            let key,
            let destination,
            let imported,
            let resolution
        ):
            return
                "\(axisGroupDescription(key)) uses "
                + "\(destination.xColumn) / \(destination.yColumn) here "
                + "and \(imported.xColumn) / \(imported.yColumn) in "
                + "the import; \(resolutionDescription(resolution))."
        }
    }

    private func tagConflictDescription(
        _ kind: DatasetMetadataTagIdentityConflictKind
    ) -> String {
        switch kind {
        case .sameNameDifferentUUID:
            "The same tag name has a different identity"
        case .sameUUIDDifferentName:
            "The same tag identity has a different name"
        case .uuidAndNameMatchDifferentDestinationTags:
            "The imported identity and name match different tags"
        }
    }

    private func resolutionDescription(
        _ resolution: DatasetMetadataImportConflictResolution
    ) -> String {
        switch resolution {
        case .keptDestination:
            "kept the existing value"
        case .usedImported:
            "used the imported value"
        case .unresolved:
            "a decision is still required"
        }
    }

    private func axisGroupDescription(
        _ key: SpectrumAxisPreferenceKeyV1
    ) -> String {
        let experiment = key.experimentIdentity.map {
            " experiment \($0)"
        } ?? ""
        return "\(key.kind.label)\(experiment) group for "
            + key.sxmPath.rawValue
    }

    private func axisLabel(_ axis: SpectrumAxis) -> String {
        axis == .x ? "X-axis" : "Y-axis"
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}

private struct MetadataImportSummaryView: View {
    let summary: DatasetMetadataImportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "\(summary.actionCount) planned change"
                    + (summary.actionCount == 1 ? "" : "s")
            )
            .font(.headline)

            HStack(spacing: 8) {
                metric("Tags", summary.tagActionCount)
                metric("Associations", summary.associationActionCount)
                metric("Hidden", summary.hiddenActionCount)
                metric("Axes", summary.axisActionCount)
                metric("Skipped", summary.skippedItemCount)
                metric(
                    "Conflicts",
                    summary.resolvedConflictCount
                        + summary.unresolvedConflictCount
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(AppTheme.subtleFill)
        )
    }
}

private struct MetadataImportDetailSection: View {
    let title: String
    let icon: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) (\(lines.count))", systemImage: icon)
                .font(.headline)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(line)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.subtleFill.opacity(0.65))
        )
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
                    .disabled(!model.canOpenFolder)
                    .keyboardShortcut("o")

                    Text(model.searchResultCountText)
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
                } onClear: {
                    model.clearFilenameSearch()
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
                NSApp.keyWindow?.makeFirstResponder(nil)
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
                        : "Spectrum",
                ].joined(separator: ", ")
            )
            .accessibilityAddTraits(
                isFocused ? .isSelected : []
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(model.sidebarSelectedSpectrumIDs.contains(spectrum.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isFocused {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
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
}

private struct SpectrumStyleGlyph: View {
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
                with: .color(Color.primary.opacity(0.78)),
                style: spectrumStrokeStyle(
                    style.pattern,
                    lineWidth: lineWidth + 1.8,
                    compact: true,
                    lineCap: .butt
                )
            )
            context.stroke(
                path,
                with: .color(spectrumColor(style)),
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

struct SearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search file name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(onSubmit)
                .onExitCommand(perform: onClear)

            if !text.isEmpty {
                Button {
                    onClear()
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
        .disabled(
            !model.canDeleteFilesForContext(
                containing: file,
                tagContext: tagContext
            )
        )

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
            BrowserToolbar(model: model)

            if model.selectionActionPresentation.placement
                == .actionBar {
                SelectionActionBar(model: model)
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
            }

            Divider()

            browserContent
        }
        .background(AppTheme.page)
        .overlay {
            KeyboardArrowOverlay { direction in
                model.moveSelectionForArrow(direction)
            }
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        switch model.browserContentState {
        case .openFolder:
            BrowserStateView(
                icon: "folder.badge.plus",
                title: "Open an SXM Folder",
                message:
                    "Choose a folder containing SXM files to begin."
            ) {
                Button("Open Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.borderedProminent)
            }

        case .loadingFolder:
            BrowserStateView(
                icon: "folder",
                title: "Scanning Folder",
                message:
                    "Reading SXM files, spectra, and saved metadata.",
                showsProgress: true
            )

        case .folderFailed(let message):
            BrowserStateView(
                icon: "exclamationmark.triangle",
                title: "Folder Could Not Be Read",
                message: message
            ) {
                Button("Retry") {
                    model.retryCurrentFolder()
                }
                .buttonStyle(.borderedProminent)
                Button("Open Another Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.bordered)
            }

        case .emptyFolder:
            BrowserStateView(
                icon: "tray",
                title: "No SXM Files",
                message:
                    "This folder contains no readable SXM files."
            ) {
                Button("Open Another Folder") {
                    model.chooseFolder()
                }
                .buttonStyle(.borderedProminent)
                Button("Retry") {
                    model.retryCurrentFolder()
                }
                .buttonStyle(.bordered)
            }

        case .noSearchResults:
            BrowserStateView(
                icon: "magnifyingglass",
                title: "No Matching Files",
                message:
                    "No SXM or associated DAT filename matches this search."
            ) {
                Button("Clear Search") {
                    model.clearFilenameSearch()
                }
                .buttonStyle(.borderedProminent)
            }

        case .noVisibleFiles:
            BrowserStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Files in This View",
                message:
                    "Choose another tag or return to All files."
            )

        case .gridReady:
            GridBrowserView(model: model)

        case .noSelection:
            BrowserStateView(
                icon: "cursorarrow.click",
                title: "No File Selected",
                message:
                    "Select an SXM file, or return to Grid to browse."
            ) {
                Button("Show Grid") {
                    model.setMode(.grid)
                }
                .buttonStyle(.borderedProminent)
            }

        case .renderLoading,
             .renderReady,
             .renderFailed(_, _):
            SingleImageView(model: model)
        }
    }
}

private struct BrowserToolbar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            toolbarRow(
                layout: BrowserToolbarLayout(
                    availableWidth: proxy.size.width
                )
            )
        }
        .frame(height: 48)
        .background(AppTheme.toolbar)
    }

    @ViewBuilder
    private func toolbarRow(
        layout: BrowserToolbarLayout
    ) -> some View {
        HStack(spacing: layout.spacing) {
            Text(model.selectedFile?.filename ?? "No file selected")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    minWidth: layout.minimumFilenameWidth,
                    alignment: .leading
                )
                .layoutPriority(1)
                .accessibilityLabel("Selected file")
                .accessibilityValue(
                    model.selectedFile?.filename ?? "No file selected"
                )

            Text(model.selectedPositionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(
                    .horizontal,
                    layout == .expanded ? 8 : 2
                )
                .padding(
                    .vertical,
                    layout == .expanded ? 3 : 0
                )
                .background {
                    if layout == .expanded {
                        Capsule().fill(AppTheme.subtleFill)
                    }
                }
                .accessibilityLabel("File position")
                .accessibilityValue(model.selectedPositionText)

            Spacer(minLength: layout == .minimal ? 0 : 4)

            if layout == .minimal {
                Menu {
                    ForEach(BrowserMode.allCases) { mode in
                        Button(mode.label) {
                            model.setMode(mode)
                        }
                    }
                } label: {
                    Image(
                        systemName:
                            model.mode == .grid
                            ? "square.grid.2x2"
                            : "rectangle"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("View mode: \(model.mode.label)")
                .accessibilityLabel("View mode")
                .accessibilityValue(model.mode.label)
            } else {
                Picker(
                    "View mode",
                    selection: Binding(
                        get: { model.mode },
                        set: { model.setMode($0) }
                    )
                ) {
                    ForEach(BrowserMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(
                    width:
                        layout == .expanded
                        ? 142
                        : 112
                )
                .accessibilityLabel("View mode")
            }

            ControlGroup {
                Button {
                    model.stepSelection(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canStepSelection(by: -1))
                .help("Previous visible file")
                .accessibilityLabel("Previous visible file")

                Button {
                    model.stepSelection(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canStepSelection(by: 1))
                .help("Next visible file")
                .accessibilityLabel("Next visible file")
            }

            if model.mode == .single,
               layout == .expanded {
                ViewerZoomControls(model: model)
            }

            browserActionsMenu
        }
        .padding(
            .horizontal,
            layout == .minimal ? 8 : 14
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    private var browserActionsMenu: some View {
        Menu {
            if model.mode == .single {
                Menu("Image Zoom") {
                    Button("Fit to Window") {
                        model.fitViewer()
                    }
                    .disabled(!model.canAdjustViewerTransform)

                    Button("Actual Size (100%)") {
                        model.showViewerActualSize()
                    }
                    .disabled(!model.canAdjustViewerTransform)

                    Divider()

                    Button("Zoom In") {
                        model.zoomViewerIn()
                    }
                    .disabled(!model.canZoomViewerIn)

                    Button("Zoom Out") {
                        model.zoomViewerOut()
                    }
                    .disabled(!model.canZoomViewerOut)

                    Divider()

                    ForEach(
                        viewerZoomPresetScales,
                        id: \.self
                    ) { scale in
                        Button(
                            viewerZoomPercentageLabel(
                                for: scale
                            )
                        ) {
                            model.setViewerScale(scale)
                        }
                        .disabled(
                            !model.canAdjustViewerTransform
                        )
                    }
                }

                Divider()
            }

            if model.mode == .grid {
                Picker(
                    "Grid density",
                    selection: $model.gridDensity
                ) {
                    ForEach(GridDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }

                Button {
                    model.toggleGridSpectroscopyCards()
                } label: {
                    Label(
                        model.showsGridSpectroscopyCards
                            ? "Hide Spectrum Cards in Grid"
                            : "Show Spectrum Cards in Grid",
                        systemImage:
                            "waveform.path.ecg.rectangle"
                    )
                }
                .disabled(model.spectra.isEmpty)

                Divider()
            }

            Button {
                model.exportPNG()
            } label: {
                Label(
                    "Export PNG…",
                    systemImage: "square.and.arrow.up"
                )
            }
            .disabled(model.selectedImage == nil)

            Button {
                model.revealSelectedFilesInFinder()
            } label: {
                Label(
                    "Show in Finder",
                    systemImage: "folder"
                )
            }
            .disabled(model.selectedCount == 0)

            if model.selectionActionPresentation.placement
                == .overflow {
                Divider()
                Button(role: .destructive) {
                    model.deleteSelectedFiles()
                } label: {
                    Label(
                        "Move to Trash…",
                        systemImage: "trash"
                    )
                }
                .disabled(!model.canDeleteSelection)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More browser actions")
        .accessibilityLabel("More browser actions")
    }
}

private enum BrowserToolbarLayout: Equatable {
    case expanded
    case compact
    case minimal

    init(availableWidth: CGFloat) {
        if availableWidth >= 660 {
            self = .expanded
        } else if availableWidth >= 390 {
            self = .compact
        } else {
            self = .minimal
        }
    }

    var spacing: CGFloat {
        switch self {
        case .expanded:
            10
        case .compact:
            7
        case .minimal:
            5
        }
    }

    var minimumFilenameWidth: CGFloat {
        switch self {
        case .expanded:
            100
        case .compact:
            70
        case .minimal:
            45
        }
    }
}

private let viewerZoomPresetScales = [
    0.25,
    0.5,
    1,
    2,
    4,
    8,
    16,
]

private func viewerZoomPercentageLabel(
    for scale: Double
) -> String {
    "\(Int((scale * 100).rounded()))%"
}

private struct ViewerZoomControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Button {
                model.zoomViewerOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(!model.canZoomViewerOut)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")

            Menu {
                Button("Fit to Window") {
                    model.fitViewer()
                }
                .disabled(!model.canAdjustViewerTransform)

                Button("Actual Size (100%)") {
                    model.showViewerActualSize()
                }
                .disabled(!model.canAdjustViewerTransform)

                Divider()

                ForEach(
                    viewerZoomPresetScales,
                    id: \.self
                ) { scale in
                    Button(
                        viewerZoomPercentageLabel(
                            for: scale
                        )
                    ) {
                        model.setViewerScale(scale)
                    }
                    .disabled(!model.canAdjustViewerTransform)
                }
            } label: {
                Text(model.viewerZoomLabel)
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 62)
            }
            .disabled(!model.canAdjustViewerTransform)
            .fixedSize()
            .help("Choose image zoom")
            .accessibilityLabel("Image zoom")
            .accessibilityValue(model.viewerZoomLabel)

            Button {
                model.zoomViewerIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!model.canZoomViewerIn)
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
        }
        .controlSize(.small)
        .fixedSize()
    }
}

private struct SelectionActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Label(
                "\(model.selectedCount) selected",
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .accessibilityLabel("\(model.selectedCount) files selected")

            Spacer(minLength: 8)

            Menu {
                if model.tags.isEmpty {
                    Button("New Tag…") {
                        model.promptForNewTagForSelection()
                    }
                } else {
                    ForEach(model.tags) { tag in
                        Button(tag.name) {
                            model.addTagToSelection(tag.id)
                        }
                    }
                    Divider()
                    Button("New Tag…") {
                        model.promptForNewTagForSelection()
                    }
                }
            } label: {
                Label("Add Tag", systemImage: "tag")
            }
            .disabled(!model.canModifyTags)

            Menu {
                let removableTags = model.removableTagsForSelection()
                if removableTags.isEmpty {
                    Text("No Tags")
                } else {
                    ForEach(removableTags) { tag in
                        Button(tag.name) {
                            model.removeTagFromSelection(tag.id)
                        }
                    }
                }
            } label: {
                Label("Remove Tag", systemImage: "tag.slash")
            }
            .disabled(
                !model.canModifyTags
                    || model.removableTagsForSelection().isEmpty
            )

            Button {
                model.revealSelectedFilesInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Reveal selected files in Finder")

            Button(role: .destructive) {
                model.deleteSelectedFiles()
            } label: {
                Label("Move to Trash…", systemImage: "trash")
            }
            .disabled(!model.canDeleteSelection)
            .help("Move selected visible files to the system Trash")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.separator)
                .frame(height: 1)
        }
    }
}

struct BrowserStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    var showsProgress = false
    @ViewBuilder let actions: Actions

    init(
        icon: String,
        title: String,
        message: String,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)

            HStack(spacing: 8) {
                actions
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.stage)
    }
}

extension BrowserStateView where Actions == EmptyView {
    init(
        icon: String,
        title: String,
        message: String,
        showsProgress: Bool = false
    ) {
        self.init(
            icon: icon,
            title: title,
            message: message,
            showsProgress: showsProgress
        ) {
            EmptyView()
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

    static func dismantleNSView(
        _ nsView: KeyboardArrowCatcherView,
        coordinator: ()
    ) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class KeyboardArrowCatcherView: NSView {
    var onArrow: ((MoveCommandDirection) -> Void)?
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            installEventMonitor()
        }
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

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isEventForThisWindow(event),
              !interactiveControlHasFocus,
              hasNoCommandModifiers(event) else {
            return false
        }
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
        if let eventWindow = event.window {
            return eventWindow === window
        }
        return NSApp.keyWindow === window
    }

    private func hasNoCommandModifiers(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        return modifiers.isEmpty
    }

    private var interactiveControlHasFocus: Bool {
        guard let firstResponder =
            window?.firstResponder as? NSView else {
            return false
        }
        var view: NSView? = firstResponder
        while let current = view {
            if current is NSTextView
                || current is NSControl {
                return true
            }
            view = current.superview
        }
        return false
    }

}

struct GridBrowserView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
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
                            ForEach(model.visibleDisplayItems) { item in
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

private extension GridDensity {
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
    var isInteractive = false

    var body: some View {
        GeometryReader { proxy in
            let rect = imageRect(in: proxy.size)
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
    let style: SpectrumVisualStyle
    var isFocused = false

    var body: some View {
        ZStack {
            Circle()
                .fill(spectrumColor(style).opacity(0.26))
                .frame(width: 18, height: 18)
            Circle()
                .stroke(Color.white.opacity(0.98), lineWidth: 2)
                .frame(width: 20, height: 20)
            Circle()
                .stroke(
                    Color.black.opacity(0.78),
                    lineWidth: 1
                )
                .frame(width: 22, height: 22)

            SpectrumStyleGlyph(
                style: style,
                width: 16,
                lineWidth: 2
            )

            if isFocused {
                Circle()
                    .stroke(
                        Color.accentColor,
                        lineWidth: 2.2
                    )
                    .frame(width: 27, height: 27)
                    .shadow(
                        color: Color.accentColor.opacity(0.45),
                        radius: 2
                    )
            }
        }
        .frame(
            width: isFocused ? 29 : 24,
            height: isFocused ? 29 : 24
        )
        .shadow(
            color: .black.opacity(0.35),
            radius: 1.5,
            x: 0,
            y: 1
        )
    }
}

struct SpectroscopyPlotCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let presentation: PresentedSpectroscopyGroup

    private var group: SpectroscopyGroup {
        presentation.group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(group.title)
                .font(.caption)
                .lineLimit(1)

            HStack {
                Text(group.kind.label)
                    .lineLimit(1)
                Spacer()
                Text(presentation.visibleCurveCountText)
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
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast

    let group: SpectroscopyGroup
    let spectra: [SpectroscopyFile]
    let xColumn: String
    let yColumn: String
    var focusedSpectrumID: SpectroscopyFile.ID? = nil

    private let inset = EdgeInsets(
        top: 20,
        leading: 60,
        bottom: 43,
        trailing: 14
    )

    var body: some View {
        Canvas { context, size in
            drawPlot(context: &context, size: size)
        }
        .background(Color.white)
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

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
        drawFrame(context: &context, plot: plot)

        let ranges = dataRanges()
        drawTicks(context: &context, plot: plot, ranges: ranges)
        drawCurves(context: &context, plot: plot, ranges: ranges)

        context.draw(
            Text(group.kind.label)
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
                .foregroundColor(.black),
            at: CGPoint(x: plot.minX + 7, y: plot.minY + 7),
            anchor: .topLeading
        )
        context.draw(
            Text(xColumn)
                .font(.system(size: 11))
                .foregroundColor(.black.opacity(0.86)),
            at: CGPoint(x: plot.midX, y: size.height - 13),
            anchor: .center
        )
        var yLabelContext = context
        yLabelContext.translateBy(x: 12, y: plot.midY)
        yLabelContext.rotate(by: .degrees(-90))
        yLabelContext.draw(
            Text(yColumn)
                .font(.system(size: 11))
                .foregroundColor(.black.opacity(0.86)),
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
                Text(compact(value))
                    .font(.system(size: 10))
                    .foregroundColor(.black),
                at: CGPoint(x: x, y: plot.maxY + 9),
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
                Text(compact(value))
                    .font(.system(size: 10))
                    .foregroundColor(.black),
                at: CGPoint(x: plot.minX - 7, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawCurves(context: inout GraphicsContext, plot: CGRect, ranges: (xMin: Double, xMax: Double, yMin: Double, yMax: Double)) {
        let orderedSpectra = spectra.filter {
            $0.id != focusedSpectrumID
        } + spectra.filter {
            $0.id == focusedSpectrumID
        }
        for spectrum in orderedSpectra {
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
            let isFocused = spectrum.id == focusedSpectrumID
            let visualStyle = spectrumVisualStyle(
                for: spectrum
            )
            let underlayWidth: CGFloat
            let colorWidth: CGFloat
            if isFocused {
                underlayWidth =
                    colorSchemeContrast == .increased
                    ? 5.2
                    : 4.6
                colorWidth =
                    colorSchemeContrast == .increased
                    ? 3.2
                    : 2.8
            } else {
                underlayWidth =
                    colorSchemeContrast == .increased
                    ? 3.4
                    : 2.8
                colorWidth =
                    colorSchemeContrast == .increased
                    ? 2
                    : 1.7
            }
            if isFocused {
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.92)),
                    style: spectrumStrokeStyle(
                        visualStyle.pattern,
                        lineWidth: underlayWidth + 2,
                        lineCap: .butt
                    )
                )
            }
            context.stroke(
                path,
                with: .color(.black.opacity(0.72)),
                style: spectrumStrokeStyle(
                    visualStyle.pattern,
                    lineWidth: underlayWidth,
                    lineCap: .butt
                )
            )
            context.stroke(
                path,
                with: .color(spectrumColor(visualStyle)),
                style: spectrumStrokeStyle(
                    visualStyle.pattern,
                    lineWidth: colorWidth
                )
            )
        }
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
        let points = spectra.flatMap {
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

private func spectrumVisualStyle(
    for spectrum: SpectroscopyFile
) -> SpectrumVisualStyle {
    SpectrumVisualStyle.resolve(
        index: spectrum.colorIndex
    )
}

private func spectrumColor(
    _ style: SpectrumVisualStyle
) -> Color {
    Color(
        .sRGB,
        red: style.color.normalizedRed,
        green: style.color.normalizedGreen,
        blue: style.color.normalizedBlue,
        opacity: 1
    )
}

private func spectrumStrokeStyle(
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

private func spectrumStyleDescription(
    for spectrum: SpectroscopyFile
) -> String {
    spectrumStyleDescription(
        spectrumVisualStyle(for: spectrum)
    )
}

private func spectrumStyleDescription(
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


struct SingleImageView: View {
    @ObservedObject var model: AppModel
    @State private var liveDrawerHeight: CGFloat
    @State private var isResizingDrawer = false

    init(model: AppModel) {
        self.model = model
        _liveDrawerHeight = State(
            initialValue: CGFloat(
                model.singleSpectroscopyState.height
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SingleImageCanvas(model: model)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .layoutPriority(1)

            SingleSpectroscopyDrawer(
                model: model,
                liveHeight: $liveDrawerHeight,
                isResizing: $isResizingDrawer
            )
        }
        .onChange(
            of: model.singleSpectroscopyState.height
        ) { _, height in
            if !isResizingDrawer {
                liveDrawerHeight = CGFloat(height)
            }
        }
        .transaction { transaction in
            if isResizingDrawer {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct SingleImageCanvas: View {
    @ObservedObject var model: AppModel
    @State private var dragStartTransform:
        ViewerTransform?
    @State private var magnifyStartTransform:
        ViewerTransform?
    @State private var gestureTransform:
        ViewerTransform?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.stage
                switch model.browserContentState {
                case .renderReady:
                    if let frame = model.renderedFrame,
                       frame.request.fileID == model.selectedID,
                       let file = model.files.first(where: {
                           $0.id == frame.request.fileID
                       }) {
                        readyCanvas(
                            frame: frame,
                            file: file,
                            availableSize: proxy.size
                        )
                    } else {
                        ProgressView()
                    }
                case .renderLoading:
                    BrowserStateView(
                        icon: "photo",
                        title: "Rendering Image",
                        message:
                            "Preparing the selected channel "
                            + "and statistics.",
                        showsProgress: true
                    )
                case .renderFailed(_, let message):
                    BrowserStateView(
                        icon: "exclamationmark.octagon",
                        title: "Image Could Not Be Rendered",
                        message: message
                    ) {
                        Button("Retry") {
                            model.retrySelectedRender()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Show in Finder") {
                            model.revealSelectedFileInFinder()
                        }
                        .buttonStyle(.bordered)
                    }
                default:
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .onChange(of: model.selectedID) { _, _ in
                clearGesturePreview()
            }
        }
    }

    @ViewBuilder
    private func readyCanvas(
        frame: CoordinatorRenderedFrame,
        file: SXMMetadata,
        availableSize: CGSize
    ) -> some View {
        let viewportSize = CGSize(
            width: max(1, availableSize.width - 36),
            height: max(1, availableSize.height - 36)
        )
        let imageSize = CGSize(
            width: max(1, CGFloat(file.pixels.width)),
            height: max(1, CGFloat(file.pixels.height))
        )
        let geometry = ViewerCanvasGeometry(
            imageSize: imageSize,
            viewportSize: viewportSize
        )
        let displayedTransform = reconciledTransform(
            gestureTransform ?? model.viewerTransform,
            geometry: geometry
        )
        let scaledImageSize = CGSize(
            width:
                imageSize.width
                * displayedTransform.scale,
            height:
                imageSize.height
                * displayedTransform.scale
        )
        let activeProbe = model.probeReading(for: frame)
        let visibleImageRect = CGRect(
            x: displayedTransform.translation.x,
            y: displayedTransform.translation.y,
            width: scaledImageSize.width,
            height: scaledImageSize.height
        ).intersection(
            CGRect(
                origin: .zero,
                size: viewportSize
            )
        )
        let scaleBar = resolvedScaleBar(
            for: file,
            transform: displayedTransform,
            visibleImageRect: visibleImageRect
        )

        ZStack(alignment: .topLeading) {
            ZStack {
                Image(nsImage: frame.image)
                    .resizable()
                    .interpolation(.none)
                    .frame(
                        width: scaledImageSize.width,
                        height: scaledImageSize.height
                    )

                SpectroscopyMarkerLayer(
                    model: model,
                    file: file,
                    isInteractive: true
                )
                .frame(
                    width: scaledImageSize.width,
                    height: scaledImageSize.height
                )
            }
            .frame(
                width: scaledImageSize.width,
                height: scaledImageSize.height
            )
            .offset(
                x: displayedTransform.translation.x,
                y: displayedTransform.translation.y
            )

            if let activeProbe {
                if let center =
                    activeProbe.pixelCoordinate.viewportCenter(
                        viewerTransform: displayedTransform,
                        pixelWidth: file.pixels.width,
                        pixelHeight: file.pixels.height
                    ) {
                    ProbeReticle()
                        .position(
                            x: center.x,
                            y: center.y
                        )
                }

                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        ProbeReadingCard(
                            reading: activeProbe
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .allowsHitTesting(false)
            }

            if let scaleBar {
                let overlayWidth =
                    CGFloat(scaleBar.screenLengthPoints)
                    + 16
                ScreenScaleBar(scaleBar: scaleBar)
                    .frame(
                        width: overlayWidth,
                        height: 42
                    )
                    .position(
                        x:
                            visibleImageRect.minX
                            + 10
                            + overlayWidth / 2,
                        y:
                            visibleImageRect.maxY
                            - 29
                    )
            }
        }
        .frame(
            width: viewportSize.width,
            height: viewportSize.height,
            alignment: .topLeading
        )
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            panGesture(
                startingFrom: displayedTransform
            )
        )
        .simultaneousGesture(
            magnifyGesture(
                startingFrom: displayedTransform
            )
        )
        .onContinuousHover(
            coordinateSpace: .local
        ) { phase in
            switch phase {
            case .active(let location):
                model.updateProbeReading(
                    at: location,
                    using: displayedTransform,
                    request: frame.request
                )
            case .ended:
                model.clearProbeReading()
            }
        }
        .onAppear {
            model.reconcileViewerGeometry(
                imageSize: imageSize,
                viewportSize: viewportSize
            )
        }
        .onChange(of: geometry) { _, updated in
            clearGesturePreview()
            model.reconcileViewerGeometry(
                imageSize: updated.imageSize,
                viewportSize: updated.viewportSize
            )
        }
        .onChange(of: frame.request.requestID) { _, _ in
            clearGesturePreview()
        }
        .onDisappear {
            model.clearProbeReading()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image viewer")
        .accessibilityValue(
            viewerAccessibilityValue(
                probe: activeProbe
            )
        )
    }

    private func panGesture(
        startingFrom displayedTransform: ViewerTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                model.clearProbeReading()
                if dragStartTransform == nil {
                    dragStartTransform =
                        displayedTransform
                }
                guard var preview =
                    dragStartTransform else {
                    return
                }
                preview.pan(
                    by: ViewerPoint(
                        x: value.translation.width,
                        y: value.translation.height
                    )
                )
                gestureTransform = preview
            }
            .onEnded { _ in
                commitGesturePreview()
            }
    }

    private func magnifyGesture(
        startingFrom displayedTransform: ViewerTransform
    ) -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                model.clearProbeReading()
                if magnifyStartTransform == nil {
                    magnifyStartTransform =
                        displayedTransform
                }
                guard var preview =
                    magnifyStartTransform else {
                    return
                }
                preview.setCustomScale(
                    preview.scale * Double(value),
                    around: preview.viewportSize.center
                )
                gestureTransform = preview
            }
            .onEnded { _ in
                commitGesturePreview()
            }
    }

    private func reconciledTransform(
        _ transform: ViewerTransform,
        geometry: ViewerCanvasGeometry
    ) -> ViewerTransform {
        var resolved = transform
        resolved.reconcile(
            imageSize: ViewerSize(
                width: geometry.imageSize.width,
                height: geometry.imageSize.height
            ),
            viewportSize: ViewerSize(
                width: geometry.viewportSize.width,
                height: geometry.viewportSize.height
            )
        )
        return resolved
    }

    private func commitGesturePreview() {
        if let gestureTransform {
            model.commitViewerTransform(
                gestureTransform
            )
        }
        clearGesturePreview()
    }

    private func clearGesturePreview() {
        dragStartTransform = nil
        magnifyStartTransform = nil
        gestureTransform = nil
    }

    private func viewerAccessibilityValue(
        probe: ProbeReading?
    ) -> String {
        guard let probe else {
            return model.viewerZoomLabel
        }
        return [
            model.viewerZoomLabel,
            probeAccessibilitySummary(probe),
        ].joined(separator: ", ")
    }

    private func resolvedScaleBar(
        for file: SXMMetadata,
        transform: ViewerTransform,
        visibleImageRect: CGRect
    ) -> ScaleBar? {
        guard let scanRangeX = file.scanRange?.x,
              !visibleImageRect.isNull,
              visibleImageRect.width >= 76,
              visibleImageRect.height >= 54 else {
            return nil
        }
        return ScaleBar.resolve(
            scanRangeX: scanRangeX,
            sourcePixelWidth: file.pixels.width,
            viewerTransform: transform,
            availableWidth:
                visibleImageRect.width - 28
        )
    }
}

private struct ViewerCanvasGeometry: Equatable {
    let imageSize: CGSize
    let viewportSize: CGSize
}

private struct ProbeReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.34))
                .frame(width: 15, height: 15)
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: 11, height: 11)
            Rectangle()
                .fill(Color.white)
                .frame(width: 17, height: 1)
            Rectangle()
                .fill(Color.white)
                .frame(width: 1, height: 17)
        }
        .frame(width: 20, height: 20)
        .shadow(
            color: Color.black.opacity(0.75),
            radius: 1,
            x: 0,
            y: 1
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProbeReadingCard: View {
    let reading: ProbeReading

    var body: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 9,
            verticalSpacing: 3
        ) {
            GridRow {
                Text("Pixel")
                Text(
                    "\(reading.pixelCoordinate.x), "
                        + "\(reading.pixelCoordinate.y)"
                )
                .gridColumnAlignment(.trailing)
            }
            GridRow {
                Text("Raw")
                Text(
                    formattedProbeValue(
                        reading.rawValue,
                        unit: reading.unit
                    )
                )
                .gridColumnAlignment(.trailing)
            }
            GridRow {
                Text("Processed")
                Text(
                    formattedProbeValue(
                        reading.processedValue,
                        unit: reading.unit
                    )
                )
                .gridColumnAlignment(.trailing)
            }
            if let physical = reading.physicalCoordinate {
                GridRow {
                    Text("Position")
                    Text(
                        "X "
                            + formattedProbeValue(
                                physical.x,
                                unit: "m"
                            )
                            + " · Y "
                            + formattedProbeValue(
                                physical.y,
                                unit: "m"
                            )
                    )
                    .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    Color.primary.opacity(0.14),
                    lineWidth: 1
                )
        }
        .shadow(
            color: Color.black.opacity(0.18),
            radius: 5,
            x: 0,
            y: 2
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Data probe")
        .accessibilityValue(
            probeAccessibilitySummary(reading)
        )
    }
}

private struct ScreenScaleBar: View {
    let scaleBar: ScaleBar

    var body: some View {
        VStack(spacing: 4) {
            Text(scaleBar.label)
                .font(.caption.weight(.semibold))
                .monospacedDigit()

            ScaleBarGlyph()
                .stroke(
                    Color.black.opacity(0.90),
                    style: StrokeStyle(
                        lineWidth: 5,
                        lineCap: .square,
                        lineJoin: .miter
                    )
                )
                .overlay {
                    ScaleBarGlyph()
                        .stroke(
                            Color.white,
                            style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .square,
                                lineJoin: .miter
                            )
                        )
                }
                .frame(
                    width:
                        CGFloat(
                            scaleBar.screenLengthPoints
                        ),
                    height: 10
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    Color.primary.opacity(0.14),
                    lineWidth: 1
                )
        }
        .shadow(
            color: Color.black.opacity(0.18),
            radius: 4,
            x: 0,
            y: 2
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale bar")
        .accessibilityValue(scaleBar.label)
    }
}

private struct ScaleBarGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerY = rect.midY
        path.move(
            to: CGPoint(
                x: rect.minX,
                y: centerY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX,
                y: centerY
            )
        )
        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.maxY
            )
        )
        path.move(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX,
                y: rect.maxY
            )
        )
        return path
    }
}

private struct SingleSpectroscopyDrawer: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    @Binding var liveHeight: CGFloat
    @Binding var isResizing: Bool
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
            minHeight: isExpanded ? liveHeight : 42,
            maxHeight: isExpanded ? liveHeight : 42
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
        .animation(
            .easeInOut(duration: 0.18),
            value: isExpanded
        )
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
                            dragStartHeight = liveHeight
                            isResizing = true
                        }
                        let start =
                            dragStartHeight ?? liveHeight
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
                            liveHeight = CGFloat(next)
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
                Image(
                    systemName: isExpanded
                        ? "chevron.down"
                        : "chevron.right"
                )
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
                        .focusedSpectrumID
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

private struct SpectroscopyLegend: View {
    @ObservedObject var model: AppModel
    let presentation: PresentedSpectroscopyGroup

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
                .fill(AppTheme.subtleFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    Color.secondary.opacity(0.18),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spectrum curve legend")
    }
}

private struct SpectroscopyLegendRow: View {
    @ObservedObject var model: AppModel
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

private func formattedProbeValue(
    _ value: Double?,
    unit: String
) -> String {
    guard let value, value.isFinite else {
        return "Not finite"
    }
    let formatted = compact(value)
    guard !unit.isEmpty else { return formatted }
    if value == 0 {
        return "\(formatted) \(unit)"
    }
    return "\(formatted)\(unit)"
}

private func probeAccessibilitySummary(
    _ reading: ProbeReading
) -> String {
    var fields = [
        "Pixel \(reading.pixelCoordinate.x), "
            + "\(reading.pixelCoordinate.y), zero based",
        "Raw "
            + formattedProbeValue(
                reading.rawValue,
                unit: reading.unit
            ),
        "Processed "
            + formattedProbeValue(
                reading.processedValue,
                unit: reading.unit
            ),
    ]
    if let physical = reading.physicalCoordinate {
        fields.append(
            "Position X "
                + formattedProbeValue(
                    physical.x,
                    unit: "m"
                )
                + ", Y "
                + formattedProbeValue(
                    physical.y,
                    unit: "m"
                )
        )
    }
    return fields.joined(separator: ", ")
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
