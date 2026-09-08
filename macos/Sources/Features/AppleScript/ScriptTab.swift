import AppKit

/// AppleScript-facing wrapper around a single tab in a scripting window.
///
/// `ScriptWindow.tabs` vends these objects so AppleScript can traverse
/// `window -> tab` without knowing anything about AppKit controllers.
@MainActor
@objc(GhosttyScriptTab)
final class ScriptTab: NSObject {
    /// Stable identifier used by AppleScript `tab id "..."` references.
    private let stableID: String

    /// Weak back-reference to the scripting window that owns this tab wrapper.
    ///
    /// We only need this for dynamic properties (`index`, `selected`) and for
    /// building an object specifier path.
    private weak var window: ScriptWindow?

    /// Live terminal controller for this tab.
    ///
    /// This can become `nil` if the tab closes while a script is running.
    private weak var controller: BaseTerminalController?

    /// The tab within `controller`, when the controller owns its own tabs
    /// (`macos-non-native-tabs`). With native tabbing a controller IS a tab,
    /// so this is nil and everything reads through the controller.
    private weak var tab: TerminalTab?

    /// Called by `ScriptWindow.tabs` / `ScriptWindow.selectedTab`.
    ///
    /// The ID is computed once so object specifiers built from this instance keep
    /// a consistent tab identity.
    init(window: ScriptWindow, controller: BaseTerminalController, tab: TerminalTab? = nil) {
        self.stableID = Self.stableID(controller: controller, tab: tab)
        self.window = window
        self.controller = controller
        self.tab = tab
    }

    /// The surfaces in this tab.
    private var surfaces: [Ghostty.SurfaceView] {
        if let tab { return tab.surfaces }
        return controller?.allSurfaces ?? []
    }

    /// Exposed as the AppleScript `id` property.
    @objc(id)
    var idValue: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        return stableID
    }

    /// Exposed as the AppleScript `title` property.
    ///
    /// Returns the title of the tab's window.
    @objc(title)
    var title: String {
        guard NSApp.isAppleScriptEnabled else { return "" }
        if let tab { return tab.title }
        return controller?.window?.title ?? ""
    }

    /// Exposed as the AppleScript `index` property.
    ///
    /// Cocoa scripting expects this to be 1-based for user-facing collections.
    @objc(index)
    var index: Int {
        guard NSApp.isAppleScriptEnabled else { return 0 }
        guard let controller else { return 0 }
        return window?.tabIndex(for: controller, tab: tab) ?? 0
    }

    /// Exposed as the AppleScript `selected` property.
    ///
    /// Powers script conditions such as `if selected of tab 1 then ...`.
    @objc(selected)
    var selected: Bool {
        guard NSApp.isAppleScriptEnabled else { return false }
        guard let controller else { return false }
        return window?.tabIsSelected(controller, tab: tab) ?? false
    }

    /// Exposed as the AppleScript `focused terminal` property.
    ///
    /// Uses the currently focused surface for this tab.
    @objc(focusedTerminal)
    var focusedTerminal: ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        if let tab {
            guard let surface = tab.focusedSurface ?? tab.surfaces.first else { return nil }
            return ScriptTerminal(surfaceView: surface)
        }

        guard let controller else { return nil }
        guard let surface = controller.focusedSurface,
              controller.surfaceTree.contains(surface)
        else { return nil }

        return ScriptTerminal(surfaceView: surface)
    }

    /// Best-effort native window containing this tab.
    var parentWindow: NSWindow? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller?.window
    }

    /// Live controller backing this tab wrapper.
    var parentController: BaseTerminalController? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return controller
    }

    /// Exposed as the AppleScript `terminals` element on a tab.
    ///
    /// Returns all terminal surfaces (split panes) within this tab.
    @objc(terminals)
    var terminals: [ScriptTerminal] {
        guard NSApp.isAppleScriptEnabled else { return [] }
        return surfaces.map(ScriptTerminal.init)
    }

    /// Enables unique-ID lookup for `terminals` references on a tab.
    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> ScriptTerminal? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        return surfaces
            .first(where: { $0.id.uuidString == uniqueID })
            .map(ScriptTerminal.init)
    }

    /// Handler for `select tab <tab>`.
    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        // We only ever hold a tab when the controller owns its own tabs, which
        // is the only kind of controller that can select one.
        if let tab, let controller = controller as? TerminalController {
            controller.selectTab(tab)
            controller.window?.makeKeyAndOrderFront(nil)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        tabContainerWindow.makeKeyAndOrderFront(nil)
        return nil
    }

    /// Handler for `close tab <tab>`.
    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard NSApp.validateScript(command: command) else { return nil }

        guard let tabController = parentController else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab is no longer available."
            return nil
        }

        if let managedTerminalController = tabController as? TerminalController {
            managedTerminalController.closeTabImmediately(tab, registerRedo: false)
            return nil
        }

        guard let tabContainerWindow = parentWindow else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "Tab container window is no longer available."
            return nil
        }

        tabContainerWindow.close()
        return nil
    }

    /// Provides Cocoa scripting with a canonical "path" back to this object.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard NSApp.isAppleScriptEnabled else { return nil }
        guard let window else { return nil }
        guard let windowClassDescription = window.classDescription as? NSScriptClassDescription else {
            return nil
        }
        guard let windowSpecifier = window.objectSpecifier else { return nil }

        // This tells Cocoa how to re-find this tab later:
        // application -> scriptWindows[id] -> tabs[id].
        return NSUniqueIDSpecifier(
            containerClassDescription: windowClassDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}

extension ScriptTab {
    /// Stable ID for one tab controller.
    ///
    /// Tab identity belongs to `ScriptTab`, so both tab creation and tab ID
    /// lookups in `ScriptWindow` call this helper.
    static func stableID(controller: BaseTerminalController, tab: TerminalTab? = nil) -> String {
        if let tab { return "tab-\(tab.id.uuidString)" }
        return "tab-\(ObjectIdentifier(controller).hexString)"
    }
}
