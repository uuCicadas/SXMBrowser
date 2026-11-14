import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    let filenameSearchFocus: FocusState<Bool>.Binding

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
                        .accessibilityLabel("Search results")
                        .accessibilityValue(
                            model.searchResultCountText
                        )

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
                        .accessibilityLabel("Show scan issues")
                        .accessibilityValue(
                            "\(model.scanIssues.count) issues"
                        )
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
                ), isFocused: filenameSearchFocus) {
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

            SidebarStatusFooter(dataset: model.dataset)
        }
        .padding(12)
    }
}

private struct SidebarStatusFooter: View {
    let dataset: DatasetSessionController

    var body: some View {
        Text(dataset.status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 2)
    }
}

