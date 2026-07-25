import Testing
@testable import SXMBrowserAppCore

@Test
func responsivePaneLayoutUsesExactWidthBreakpoints() {
    let compact = ResponsivePaneLayout(containerWidth: 899.999)
    #expect(compact.regime == .compact)
    #expect(compact.sidebarPlacement == .overlay)
    #expect(compact.inspectorPlacement == .overlay)

    let medium = ResponsivePaneLayout(containerWidth: 900)
    #expect(medium.regime == .medium)
    #expect(medium.sidebarPlacement == .inline)
    #expect(medium.inspectorPlacement == .overlay)

    let expanded = ResponsivePaneLayout(containerWidth: 1_200)
    #expect(expanded.regime == .expanded)
    #expect(expanded.sidebarPlacement == .inline)
    #expect(expanded.inspectorPlacement == .inline)
}

@Test
func responsivePaneLayoutKeepsNarrowAndInvalidWidthsCompact() {
    for width in [
        -Double.infinity,
        -1,
        0,
        760,
        Double.nan,
    ] {
        let layout = ResponsivePaneLayout(containerWidth: width)
        #expect(layout.regime == .compact)
        #expect(layout.sidebarPlacement == .overlay)
        #expect(layout.inspectorPlacement == .overlay)
    }
}
