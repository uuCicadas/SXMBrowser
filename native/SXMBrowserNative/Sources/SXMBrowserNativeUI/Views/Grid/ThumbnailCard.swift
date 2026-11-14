import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct ThumbnailCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast
    let model: AppModel
    let file: SXMMetadata
    @State private var image: NSImage?
    @State private var isHovered = false

    private var isSelected: Bool {
        model.selectedIDs.contains(file.id)
    }

    private var isCurrent: Bool {
        model.selectedID == file.id
    }

    private var thumbnailTaskID: String {
        let modifiedBits = String(file.modifiedTime.timeIntervalSince1970.bitPattern, radix: 16)
        if isCurrent {
            return [
                file.id.uuidString,
                modifiedBits,
                "selected",
                model.selectedChannel,
                model.selectedDirection.rawValue,
                model.selectedProcessing.rawValue,
                model.selectedPalette.rawValue,
                String(model.invertPalette)
            ].joined(separator: "|")
        }
        return "\(file.id.uuidString)|\(modifiedBits)|default|\(model.stmPreviewPalette.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(AppTheme.imageWell(for: colorScheme))
                if let image {
                    LayerImageView(
                        image: image,
                        scaling: .aspectFit,
                        filter: .linear
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .browserMotion(.feedback, value: image != nil)

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
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(isHovered && !isSelected ? 0.045 : 0))
                }
                .browserMotion(.feedback, value: isSelected)
                .browserMotion(.feedback, value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(
                            isCurrent ? 1 : 0.8
                        )
                        : (isHovered ? Color.accentColor.opacity(0.45) : AppTheme.tileBorder(for: colorScheme)),
                    lineWidth:
                        colorSchemeContrast == .increased
                        ? (
                            isCurrent
                            ? 3
                            : (isSelected ? 2.4 : 1.5)
                        )
                        : (
                            isCurrent
                            ? 1.8
                            : (isSelected ? 1.3 : 1)
                        )
                )
                .browserMotion(.feedback, value: isSelected)
                .browserMotion(.feedback, value: isCurrent)
                .browserMotion(.feedback, value: isHovered)
        )
        .overlay(alignment: .topTrailing) {
            ZStack {
                if isSelected {
                    Image(
                        systemName:
                            isCurrent
                            ? "checkmark.circle.fill"
                            : "checkmark.circle"
                    )
                    .font(.system(size: 17, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        Color.white,
                        Color.accentColor
                    )
                    .padding(13)
                    .shadow(
                        color: Color.black.opacity(0.65),
                        radius: 2
                    )
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .browserMotion(.feedback, value: isSelected)
        }
        .onHover { isHovered = $0 }
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.10) : Color.black.opacity(0.045),
            radius: isSelected ? 8 : 5,
            x: 0,
            y: isSelected ? 3 : 2
        )
        .contentShape(Rectangle())
        .overlay {
            InstantClickOverlay { disposition in
                model.requestFilenameSearchBlur()
                switch disposition {
                case .select(let modifiers):
                    model.select(file, modifiers: modifiers.eventModifierFlags)
                case .selectAndOpenSingle:
                    model.select(file)
                    model.setMode(.single)
                case .ignore:
                    break
                }
            }
        }
        .contextMenu {
            FileContextMenu(model: model, file: file)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.filename)
        .accessibilityValue(
            [
                isCurrent
                    ? "Current file"
                    : (isSelected ? "Selected file" : "Not selected"),
                "\(file.pixels.width) by "
                    + "\(file.pixels.height) pixels",
                file.defaultChannel.map {
                    "Channel \($0)"
                },
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(
            isSelected ? .isSelected : []
        )
        .accessibilityHint(
            "Activate to select. Open action shows Single view."
        )
        .accessibilityAction {
            model.requestFilenameSearchBlur()
            model.select(file)
        }
        .accessibilityAction(named: "Open in Single view") {
            model.requestFilenameSearchBlur()
            model.select(file)
            model.setMode(.single)
        }
        .task(id: thumbnailTaskID) {
            let thumbnail = await model.thumbnail(for: file, usingSelection: isCurrent)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
    }
}

