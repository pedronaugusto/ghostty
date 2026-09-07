import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8 (1.4.0)

        /// Every tab in the window, in order, when Ghostty owns the tabs.
        ///
        /// This MUST stay optional. A non-optional field throws while decoding
        /// any older blob, `CodableBridge.init?` then returns nil, and
        /// `restoreWindow` loses the whole window rather than degrading.
        ///
        /// The version 5 fields above keep describing the active tab, so an
        /// older Ghostty reading a version 8 blob still restores that one.
        let tabs: [TabState<ViewType>]?
        let activeTabIndex: Int?

        /// A single tab within `tabs`.
        struct TabState<TabViewType: NSView & Codable & Identifiable>: Codable {
            let surfaceTree: SplitTree<TabViewType>
            let focusedSurface: String?
            let titleOverride: String?
            let tabColor: TerminalTabColor?
        }
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            tabs: controller.usesNonNativeTabs ? controller.tabs.map { tab in
                .init(
                    surfaceTree: tab.surfaceTree,
                    focusedSurface: tab.focusedSurface?.id.uuidString,
                    titleOverride: tab.titleOverride,
                    tabColor: tab.tabColor)
            } : nil,
            activeTabIndex: controller.usesNonNativeTabs ? controller.activeTabIndex : nil,
        )
    }
}
