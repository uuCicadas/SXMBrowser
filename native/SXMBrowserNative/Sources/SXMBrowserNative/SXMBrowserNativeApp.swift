import SXMBrowserAppCore
import SXMBrowserNativeUI
import SwiftUI

@main
struct SXMBrowserNativeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            ToolbarCommands()

            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    model.chooseFolder()
                }
                .keyboardShortcut("o")
                .disabled(!model.canOpenFolder)

                Button("Show in Finder") {
                    model.revealSelectedFilesInFinder()
                }
                .disabled(model.selectedCount == 0)
            }

            CommandGroup(replacing: .importExport) {
                Button("Export PNG…") {
                    model.exportPNG()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedImage == nil)

                Divider()

                Button("Export Metadata…") {
                    model.exportMetadata()
                }
                .disabled(!model.canExportMetadata)

                Button("Import Metadata…") {
                    model.importMetadata()
                }
                .disabled(!model.canImportMetadata)
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    model.selectAll()
                }
                .keyboardShortcut("a")

                Button("Move Selected SXM Files to Trash…") {
                    model.deleteSelectedFiles()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!model.canDeleteSelection)

                Divider()

                Button("Find Files…") {
                    model.requestFilenameSearchFocus()
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            CommandGroup(before: .toolbar) {
                Picker("Browser View", selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    Text("Grid").tag(BrowserMode.grid)
                    Text("Single Image").tag(BrowserMode.single)
                }
                .pickerStyle(.inline)

                Divider()

                Button("Previous File") {
                    model.stepSelection(-1)
                }
                .disabled(!model.canStepSelection(by: -1))

                Button("Next File") {
                    model.stepSelection(1)
                }
                .disabled(!model.canStepSelection(by: 1))

                Divider()

                imageZoomMenu

                Picker("Grid Density", selection: $model.gridDensity) {
                    Text("Compact").tag(GridDensity.compact)
                    Text("Comfortable").tag(GridDensity.comfortable)
                    Text("Large").tag(GridDensity.large)
                }
                .disabled(model.mode != .grid)

                Button(
                    model.showsGridSpectroscopyCards
                        ? "Hide Spectrum Cards in Grid"
                        : "Show Spectrum Cards in Grid"
                ) {
                    model.toggleGridSpectroscopyCards()
                }
                .disabled(model.mode != .grid || model.spectra.isEmpty)

                Divider()
            }

            CommandGroup(replacing: .sidebar) {
                Button(model.actualSidebarVisible ? "Hide File List" : "Show File List") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button(model.actualInspectorVisible ? "Hide Inspector" : "Show Inspector") {
                    model.toggleInspector()
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Divider()

                Button("Reset Layout") {
                    model.resetLayout()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
    }

    private var imageZoomMenu: some View {
        Menu("Image Zoom") {
            Button("Fit Image to Window") {
                model.fitViewer()
            }
            .keyboardShortcut("9", modifiers: [.command])
            .disabled(!model.canAdjustViewerTransform)

            Button("Actual Size (100%)") {
                model.showViewerActualSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!model.canAdjustViewerTransform)

            Divider()

            Button("Zoom In") {
                model.zoomViewerIn()
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(!model.canZoomViewerIn)

            Button("Zoom Out") {
                model.zoomViewerOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(!model.canZoomViewerOut)

            Divider()

            ForEach([0.25, 0.5, 1, 2, 4, 8, 16], id: \.self) { scale in
                Button("\(Int(scale * 100))%") {
                    model.setViewerScale(scale)
                }
                .disabled(!model.canAdjustViewerTransform)
            }
        }
    }
}
