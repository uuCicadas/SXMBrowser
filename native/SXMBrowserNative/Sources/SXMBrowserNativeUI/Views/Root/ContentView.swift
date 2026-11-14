import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: AppModel
    @State private var isDropTargeted = false
    @FocusState private var isFilenameSearchFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        workspaceContent
            .background(AppTheme.page)
            .overlay { dropTargetOverlay }
            .browserMotion(.feedback, value: isDropTargeted)
            .overlay(alignment: .bottom) { toastOverlay }
            .browserMotion(.disclosure, value: model.noticePresentation)
            .browserMotion(.disclosure, value: model.shouldPresentMetadataWarning)
            .frame(minWidth: 680, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
            .navigationTitle(model.selectedFile?.filename ?? "SXM Browser")
            .toolbar(id: "SXM Browser.MainToolbar") {
                BrowserToolbar(model: model)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                handleFileDrop(providers)
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
            .onAppear { model.openStartupFolder() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.willStartLiveResizeNotification
                )
            ) { _ in
                model.setViewportResizing(true)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didEndLiveResizeNotification
                )
            ) { _ in
                model.setViewportResizing(false)
            }
            .onChange(
                of: model.filenameSearchFocusRequestID
            ) { _, requestID in
                guard requestID != nil else { return }
                DispatchQueue.main.async {
                    isFilenameSearchFocused = true
                }
            }
            .onChange(
                of: model.filenameSearchBlurRequestID
            ) { _, requestID in
                guard requestID != nil else { return }
                isFilenameSearchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if let banner = model.noticePresentation.banner {
                UserNoticeBanner(
                    notice: banner,
                    onAction: model.performNoticeAction,
                    onDismiss: { model.dismissNoticeBanner(id: banner.id) }
                )
                .transition(BrowserMotion.reveal(from: .top, reduceMotion: reduceMotion))
            }

            if model.shouldPresentMetadataWarning {
                MetadataWarningStrip(model: model)
                    .transition(BrowserMotion.reveal(from: .top, reduceMotion: reduceMotion))
            }

            NativeBrowserSplitView(
                sidebarVisible: $model.isSidebarVisible,
                inspectorVisible: $model.isInspectorVisible,
                sidebarWidth: $model.sidebarWidth,
                inspectorWidth: $model.inspectorWidth,
                sidebarVisibilityRequestID: model.sidebarVisibilityRequestID,
                inspectorVisibilityRequestID: model.inspectorVisibilityRequestID,
                onVisibilityChanged: { sidebar, inspector in
                    model.updatePaneVisibility(sidebar: sidebar, inspector: inspector)
                },
                onWidthsChanged: model.saveLayoutWidths,
                onLayoutInteractionChanged: { interacting in
                    model.setSplitLayoutInteracting(interacting)
                }
            ) {
                SidebarView(model: model, filenameSearchFocus: $isFilenameSearchFocused)
            } content: {
                MainImageView(model: model)
            } inspector: {
                InspectorView(model: model)
            }
        }
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.80), lineWidth: 2.5)
                    )
                    .padding(8)

                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop Folder or SXM File to Open")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.noticePresentation.toast {
            UserNoticeToast(
                notice: toast,
                onDismiss: {
                    model.dismissNoticeToast(id: toast.id)
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .transition(BrowserMotion.reveal(from: .bottom, reduceMotion: reduceMotion))
            .zIndex(10)
        }
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
    let model: AppModel
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

