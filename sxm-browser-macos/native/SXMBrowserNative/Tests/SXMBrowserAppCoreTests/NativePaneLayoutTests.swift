import Testing
@testable import SXMBrowserAppCore

@Test
func nativePaneLayoutPreservesContentAndRestoresPreferredPanes() {
    let wide = paneLayout(width: 1_200)
    #expect(wide.showsSidebar && wide.showsInspector)
    #expect(wide.sidebarWidth == 300 && wide.inspectorWidth == 320)
    let compressed = paneLayout(width: 850)
    #expect(compressed.showsSidebar && compressed.showsInspector)
    #expect(compressed.sidebarWidth + compressed.inspectorWidth + 2 + 320 <= 850)
    let narrow = paneLayout(width: 680)
    #expect(narrow.showsSidebar && !narrow.showsInspector)
    #expect(paneLayout(width: 1_200) == wide)
    let tiny = paneLayout(width: 500)
    #expect(!tiny.showsSidebar && !tiny.showsInspector)
}

@Test
func nativePaneLayoutHonorsManualRequestWithoutErasingOtherPreference() {
    let requested = paneLayout(width: 680, priority: .inspector)
    #expect(!requested.showsSidebar && requested.showsInspector)
    let expanded = paneLayout(width: 1_200, priority: .inspector)
    #expect(expanded.showsSidebar && expanded.showsInspector)
    let hidden = paneLayout(width: 1_200, wantsSidebar: false)
    #expect(!hidden.showsSidebar && hidden.showsInspector)
}

@Test
func nativePaneLayoutValidatesWidthsAndExactFitBoundary() {
    #expect(paneLayout(width: 802).showsInspector)
    #expect(!paneLayout(width: 801.99).showsInspector)
    let invalid = NativePaneLayout(
        containerWidth: .nan, wantsSidebar: true, wantsInspector: true,
        preferredSidebarWidth: .infinity, preferredInspectorWidth: -100
    )
    #expect(!invalid.showsSidebar && !invalid.showsInspector)
    #expect(invalid.sidebarWidth == 300)
    #expect(invalid.inspectorWidth == 260)
}

private func paneLayout(
    width: Double,
    wantsSidebar: Bool = true,
    priority: NativePanePriority = .sidebar
) -> NativePaneLayout {
    NativePaneLayout(
        containerWidth: width,
        wantsSidebar: wantsSidebar,
        wantsInspector: true,
        preferredSidebarWidth: 300,
        preferredInspectorWidth: 320,
        priority: priority
    )
}
