import AppKit
import SXMBrowserAppCore
import SXMBrowserCore
import SwiftUI

struct MetadataImportPreviewSheet: View {
    let model: AppModel

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
        .frame(
            minWidth: 560, idealWidth: 640, maxWidth: 680,
            minHeight: 360, idealHeight: 480, maxHeight: 620
        )
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

