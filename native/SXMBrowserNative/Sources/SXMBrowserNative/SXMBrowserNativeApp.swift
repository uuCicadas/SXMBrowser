import SwiftUI

@main
struct SXMBrowserNativeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    model.chooseFolder()
                }
                .keyboardShortcut("o")
                .disabled(!model.canOpenFolder)

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
                .disabled(model.files.isEmpty)

                Button("Delete Selected SXM Files") {
                    model.deleteSelectedFiles()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!model.canDeleteSelection)
            }

            CommandMenu("SXM Browser") {
                Button(model.isSidebarVisible ? "Hide File List" : "Show File List") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.isSidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button(model.isInspectorVisible ? "Hide Inspector" : "Show Inspector") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.isInspectorVisible.toggle()
                    }
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Divider()

                Button("Reset Layout") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.resetLayout()
                    }
                }
                .keyboardShortcut("0", modifiers: [.command, .option])

                Divider()

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

                Button("Export PNG...") {
                    model.exportPNG()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedImage == nil)
            }
        }
    }
}
