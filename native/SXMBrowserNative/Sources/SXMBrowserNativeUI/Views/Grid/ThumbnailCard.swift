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

    private var associatedSpectrumCount: Int {
        model.spectra(for: file).count
    }

    private var footprintText: String? {
        AppTheme.formattedScanFootprint(file.scanRange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.imageWell(for: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                    )
                if let image {
                    ZStack {
                        MissingDataBackdrop(tileSize: 6)
                        LayerImageView(
                            image: image,
                            scaling: .aspectFit,
                            filter: .linear
                        )
                    }
                    .aspectRatio(
                        image.size.width > 0 && image.size.height > 0
                            ? image.size
                            : CGSize(width: 1, height: 1),
                        contentMode: .fit
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(AppTheme.hairlineBorder(for: colorScheme), lineWidth: 1)
                    )
                    .padding(6)

                    SpectroscopyMarkerLayer(model: model, file: file)
                        .padding(6)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .browserMotion(.feedback, value: image != nil)

            HStack(spacing: 6) {
                Text(file.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 2)

                if associatedSpectrumCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("\(associatedSpectrumCount)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(
                                isSelected
                                    ? Color.accentColor.opacity(colorScheme == .dark ? 0.30 : 0.16)
                                    : AppTheme.subtleFill
                            )
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }

            HStack(spacing: 4) {
                if let footprintText {
                    Text(footprintText)
                        .lineLimit(1)
                } else {
                    Text(file.defaultChannel ?? "—")
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(file.pixels.width)×\(file.pixels.height)")
                    .monospacedDigit()
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

