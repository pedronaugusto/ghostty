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
        /// Decoded with `decodeIfPresent`, and optional so that it can be.
        /// Requiring the key would throw on any older blob, `CodableBridge.init?`
        /// would return nil, and `restoreWindow` would lose the whole window
        /// rather than degrading to the active tab.
        ///
        /// The version 5 fields above keep describing the active tab, so an
        /// older Ghostty reading a version 8 blob still restores that one.
        let tabs: [TabState]?
        let activeTabIndex: Int?

        enum CodingKeys: String, CodingKey {
            case focusedSurface
            case surfaceTree
            case effectiveFullscreenMode
            case tabColor
            case titleOverride
            case tabs
            case activeTabIndex
        }

        /// A single tab within `tabs`.
        struct TabState: Codable {
            let surfaceTree: SplitTree<ViewType>
            let focusedSurface: String?
            let titleOverride: String?
            let tabColor: TerminalTabColor?
        }
    }
}

extension TerminalRestorableState.InternalState {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try container.decodeIfPresent([TabState].self, forKey: .tabs)
        activeTabIndex = try container.decodeIfPresent(Int.self, forKey: .activeTabIndex)

        if let tabs, !tabs.isEmpty {
            // Decoding a surface starts its process. The legacy key duplicates
            // the active tab for older readers and must never be decoded here.
            surfaceTree = tabs[min(max(activeTabIndex ?? 0, 0), tabs.count - 1)].surfaceTree
        } else {
            surfaceTree = try container.decode(SplitTree<ViewType>.self, forKey: .surfaceTree)
        }

        focusedSurface = try container.decodeIfPresent(String.self, forKey: .focusedSurface)
        effectiveFullscreenMode = try container.decodeIfPresent(FullscreenMode.self, forKey: .effectiveFullscreenMode)
        tabColor = try container.decodeIfPresent(TerminalTabColor.self, forKey: .tabColor)
        titleOverride = try container.decodeIfPresent(String.self, forKey: .titleOverride)
    }
}

extension TerminalRestorableState.InternalState {
    /// Which tabs get saved, and which of those the active one becomes.
    ///
    /// A tab running a command is not restorable, the same rule upstream
    /// applies to a window. Dropping them means the active index cannot be
    /// carried across: it indexes the array we write, and the version 5 keys
    /// duplicate that same tab for older readers, which would otherwise be
    /// handed the very session we are refusing to save. When the active tab is
    /// itself dropped the selection falls to the nearest tab that survived.
    ///
    /// Returns no active index when nothing is restorable, which is also when
    /// the window itself reports `isRestorable == false` and is never saved.
    static func saved(restorable: [Bool], active: Int) -> (kept: [Int], active: Int?) {
        let kept = restorable.indices.filter { restorable[$0] }
        guard !kept.isEmpty else { return ([], nil) }
        let before = restorable.prefix(max(active, 0)).filter { $0 }.count
        return (kept, min(before, kept.count - 1))
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        let selection: (kept: [Int], active: Int?) = controller.usesNonNativeTabs
            ? Self.saved(
                restorable: controller.tabs.map { $0.restorable },
                active: controller.activeTabIndex)
            : ([], nil)
        let saved = selection.kept.map { controller.tabs[$0] }
        let active = selection.active.map { saved[$0] }

        self.init(
            focusedSurface: active.map { $0.focusedSurface?.id.uuidString }
                ?? controller.focusedSurface?.id.uuidString,
            surfaceTree: active?.surfaceTree ?? controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: active?.tabColor ?? (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: active.map { $0.titleOverride } ?? controller.titleOverride,
            tabs: saved.isEmpty ? nil : saved.map { tab in
                .init(
                    surfaceTree: tab.surfaceTree,
                    focusedSurface: tab.focusedSurface?.id.uuidString,
                    titleOverride: tab.titleOverride,
                    tabColor: tab.tabColor)
            },
            activeTabIndex: selection.active,
        )
    }
}
