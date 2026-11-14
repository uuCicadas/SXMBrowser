import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct SearchField: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
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
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onClear)
                .accessibilityLabel(
                    "Search SXM and associated DAT file names"
                )
                .accessibilityHint(
                    "Type to filter files. Press Escape to clear."
                )

            if !text.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filename search")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppTheme.subtleFill.opacity(0.95))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isFocused.wrappedValue
                        ? Color.accentColor
                        : Color.clear,
                    lineWidth: 2
                )
        }
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast

    let file: SXMMetadata
    let isSelected: Bool
    let isCurrent: Bool
    var spectrumCount: Int = 0
    var isDropTargeted = false

    private var footprintText: String? {
        AppTheme.formattedScanFootprint(file.scanRange)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(file.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if spectrumCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(spectrumCount)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(
                                    isSelected
                                        ? Color.white.opacity(0.22)
                                        : AppTheme.subtleFill
                                )
                        )
                        .foregroundStyle(
                            isSelected ? Color.white : Color.secondary
                        )
                    }
                }

                HStack(spacing: 5) {
                    if let footprintText {
                        Text(footprintText)
                            .lineLimit(1)
                        Text("·")
                    }
                    Text("\(file.pixels.width)×\(file.pixels.height)")
                        .monospacedDigit()
                    if !file.channels.isEmpty {
                        Text("·")
                        Text("\(file.channels.count) ch")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(
                    isSelected
                        ? Color.white.opacity(0.88)
                        : Color.secondary
                )
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(
                    systemName:
                        isCurrent
                        ? "checkmark.circle.fill"
                        : "checkmark.circle"
                )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
            }
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
                .stroke(
                    isDropTargeted
                        ? Color.accentColor
                        : (
                            isCurrent && isSelected
                                ? Color.white.opacity(0.92)
                                : Color.clear
                        ),
                    lineWidth:
                        isDropTargeted
                        ? 2
                        : (
                            colorSchemeContrast == .increased
                            ? 2
                            : 1
                        )
                )
                .padding(1)
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .browserMotion(.feedback, value: isSelected)
        .browserMotion(.feedback, value: isCurrent)
        .browserMotion(.feedback, value: isDropTargeted)
    }
}

struct FileContextMenu: View {
    let model: AppModel
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

