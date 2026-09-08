import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller {
    override var windowNibName: NSNib.Name? {
        let defaultValue = "Terminal"

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return defaultValue }
        let config = appDelegate.ghostty.config

        // If we have no window decorations, there's no reason to do anything but
        // the default titlebar (because there will be no titlebar).
        if !config.windowDecorations {
            return defaultValue
        }

        let nib = switch config.macosTitlebarStyle {
        case .native: "Terminal"
        case .hidden: "TerminalHiddenTitlebar"
        case .transparent: "TerminalTransparentTitlebar"
        case .tabs:
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                "TerminalTabsTitlebarTahoe"
            } else {
                "TerminalTabsTitlebarVentura"
            }
#else
            "TerminalTabsTitlebarVentura"
#endif
        }

        return nib
    }

    /// Weak tab-to-controller ownership, independent of AppKit's transient view
    /// and window attachment state. A tab moves between windows by drag, and
    /// both undo and the drop target have to find where it is now.
    private static let tabControllers =
        NSMapTable<TerminalTab, TerminalController>.weakToWeakObjects()

    /// Whether we draw our own tab bar instead of using macOS native window
    /// tabbing. When this is true our window stays a single `NSWindow` however
    /// many sessions it holds.
    var usesNonNativeTabs: Bool {
        macosNonNativeTabs
    }

    /// A window keeps the tab implementation it was created with. Changing it
    /// on a live window would send its sessions through the other path and
    /// strand them.
    private let macosNonNativeTabs: Bool

    /// The tabs owned by this controller.
    ///
    /// This is non-empty from init until the window tears down, apart from the
    /// moment a tab is detached for a move elsewhere. With native tabs it
    /// always has exactly one element, because there a tab is a whole separate
    /// window with its own controller.
    @Published private(set) var tabs: [TerminalTab] = []

    /// The index into `tabs` of the tab whose content is currently displayed.
    @Published private(set) var activeTabIndex: Int = 0

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab/window that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// Whether the window we manage can be restored.
    ///
    /// A session executing a custom command is not restorable; see
    /// `TerminalTab.restorable`. Upstream stores this once per window because
    /// there a window is a session. Here a window holds many and they come and
    /// go, so the window is restorable exactly when any tab in it is, and
    /// `syncWindowRestorability` keeps AppKit in step as tabs change.
    private var restorable: Bool {
        tabs.contains { $0.restorable }
    }

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// Keeps our own tab bar in step with the tab count.
    private var tabBarCancellables: Set<AnyCancellable> = []

    /// Our own tab bar, when `macos-non-native-tabs`.
    private var tabBarAccessory: TerminalTabBarAccessoryViewController?

    /// Cancellable for spreading the bell state across our tabs.
    private var tabBellCancellable: AnyCancellable?

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil,
         adopting tab: TerminalTab? = nil
    ) {
        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)

        // Our tab bar is a titlebar accessory, so we need a titlebar to put it
        // in. `window-decoration = none` gives us a window with no titlebar at
        // all, and `macos-titlebar-style = hidden` hides the one we have. In
        // both cases we fall back to the tab behavior the window would have
        // otherwise, which for a hidden titlebar is no tabs at all (see the
        // `tabbingMode` we set in `HiddenTitlebarTerminalWindow`).
        self.macosNonNativeTabs = ghostty.config.macosNonNativeTabs &&
            ghostty.config.windowDecorations &&
            ghostty.config.macosTitlebarStyle != .hidden

        super.init(ghostty, baseConfig: base, surfaceTree: tab?.surfaceTree ?? tree)

        // Our tabs are the state we add to the base controller, and a property
        // observer can't complete them for us: the base assigns `surfaceTree`
        // inside its own initializer, where `didSet` doesn't fire.
        // A session given a command to execute is not restorable: the restored
        // session would be a shell in the same directory as the script, which
        // is meaningless. An adopted tab already carries its own answer.
        let initialTab = tab ?? TerminalTab(
            surfaceTree: surfaceTree,
            restorable: (base?.command ?? "") == "")
        tabs = [initialTab]
        activeTabIndex = 0
        Self.tabControllers.setObject(self, forKey: initialTab)

        // The base controller subscribed to our surfaces while we still had no
        // tabs to give it, so tell it they exist now.
        surfacesDidChangeSubject.send()
        setupTabBellPublisher()

        if tab != nil {
            focusedSurfaceDidChange(to: initialTab.focusedSurface ?? initialTab.surfaces.first)
            activeTabDidChange()
        }

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyTabDragEndedNoTarget(_:)),
            name: .ghosttyTabDragEndedNoTarget,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Base Controller Overrides

    override var allSurfaces: [Ghostty.SurfaceView] {
        tabs.flatMap(\.surfaces)
    }

    override var tabCount: Int {
        usesNonNativeTabs ? tabs.count : super.tabCount
    }

    override func owns(_ surface: Ghostty.SurfaceView) -> Bool {
        tabs.contains { $0.surfaceTree.contains(surface) }
    }

    override func owns(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> Bool {
        tabs.contains { $0.surfaceTree.contains(node) }
    }

    override func tree(containing surface: Ghostty.SurfaceView) -> SplitTree<Ghostty.SurfaceView>? {
        tab(owning: surface)?.surfaceTree
    }

    override func setTitleOverride(_ override: String?, for surface: Ghostty.SurfaceView) {
        guard let tab = tab(owning: surface) else { return }
        setTitleOverride(override, for: tab)
    }

    /// Set a tab's title override, whether or not it is the one on screen.
    ///
    /// The tab may have moved to another window since a caller captured it, so
    /// this always writes through whichever controller holds it now.
    func setTitleOverride(_ override: String?, for tab: TerminalTab) {
        if let owner = Self.controller(owning: tab), owner !== self {
            owner.setTitleOverride(override, for: tab)
            return
        }

        if tab === activeTab {
            // The controller owns the active tab's override, because the same
            // value is also the window's title.
            titleOverride = override
        } else {
            // A background tab's name is its own; the window is showing another one.
            tab.titleOverride = override
        }

        invalidateRestorableState()
    }

    override func promptTabTitle() {
        guard let tab = activeTab else { return }
        promptTabTitle(for: tab)
    }

    /// Prompt the user to change a tab's title.
    ///
    /// The sheet is bound to the tab it was opened for. The window outlives its
    /// tabs and stays usable while the sheet is up, so the selection can move
    /// before the user hits OK.
    func promptTabTitle(for tab: TerminalTab) {
        presentTabTitleSheet { [weak self] newTitle in
            self?.setTitleOverride(newTitle, for: tab)
        }
    }

    override func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        removeSurfaceNode(node, in: tab(owning: node))
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        containing surface: Ghostty.SurfaceView,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        replaceSurfaceTree(
            newTree,
            in: tab(owning: surface),
            // A tab we aren't showing keeps its own focus and asserts it when
            // it is next selected, so we don't move focus into it from here.
            moveFocusTo: tab(owning: surface) === activeTab ? newView : nil,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    override func prepareToFocusSurface(_ view: Ghostty.SurfaceView) -> Bool {
        guard let tab = tab(owning: view) else { return false }
        guard tab !== activeTab else { return true }

        // Selecting a tab focuses whatever it remembers, so make that this
        // surface first. Otherwise the two focus moves race.
        tab.focusedSurface = view
        selectTab(tab)
        return true
    }

    override func syncFocusToSurfaceTree() {
        // The active tab remembers where focus was, so it can put it back when
        // the user comes around to it again, and so its name follows the split
        // the user is actually looking at.
        activeTab?.focusedSurface = focusedSurface
        activeTab?.observeTitle()

        super.syncFocusToSurfaceTree()
    }

    override func titleOverrideDidChange() {
        activeTab?.titleOverride = titleOverride
        super.titleOverrideDidChange()
    }

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        // Our active tab holds the same tree this property does, and super
        // reads what we own, so the tab has to be up to date before it runs.
        syncActiveTabSurfaceTree()

        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        replaceSurfaceTree(
            newTree,
            in: activeTab,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    override func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        // The surface may be in a tab that isn't on screen: a process exiting
        // doesn't wait for the user to look at it.
        guard let tab = tab(owning: view),
              let node = tab.surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, in: tab, withConfirmation: withConfirmation)
    }

    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        closeSurface(node, in: activeTab, withConfirmation: withConfirmation)
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an App Intent) then we prefer the most previous main.
    static private(set) weak var lastMain: TerminalController?

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        if let parent, parent.styleMask.contains(.fullScreen) {
            // If our previous window was fullscreen then we want our new window to
            // be fullscreen. This behavior actually doesn't match the native tabbing
            // behavior of macOS apps where new windows create tabs when in native
            // fullscreen but this is how we've always done it. This matches iTerm2
            // behavior.
            c.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        c.scheduleInitialPresentation {
            // We're dispatching this async because in some cases AppKit will tab this window,
            // although we have a check in `windowDidLoad` and it works in most cases, but not for AppIntent
            //
            // That weird tabbing behavior only happens in the following cases at the point of writing.
            // - Creating a window via the Shortcuts app for now.
            // - Creating a window via `New Ghostty Window Here` service.
            c.showWindowSafely(self)

            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    // We're dispatching this async because otherwise the lastCascadePoint doesn't
                    // take effect after positioning in `showWindow`. Our best theory is there is
                    // some next-event-loop-tick logic that Cocoa is doing that we need to be after.
                    DispatchQueue.main.async {
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        // Calculate the target frame based on the tree's view bounds
        // before moving into the new window
        let treeSize: CGSize? = tree.root?.viewBounds()

        let c = TerminalController.init(ghostty, withSurfaceTree: tree)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        // Showing window in current event loop works so far with dragging surface into
        // a new window, but remember to defer the cascade when you move it inside
        // `scheduleInitialPresentation` to solve other issues in the future.
        c.showWindowSafely(self)
        c.scheduleInitialPresentation {
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        tree: tree,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    /// Give an existing tab a window, preserving its identity for undo.
    static func newWindow(
        _ ghostty: Ghostty.App,
        adopting tab: TerminalTab,
        position: NSPoint? = nil,
        inheritBackgroundOpacity: Bool = false,
        restoringFrame frame: NSRect? = nil
    ) -> TerminalController {
        // Capture our view bounds before detaching from the old window.
        let treeSize = tab.surfaceTree.root?.viewBounds()
        TerminalController.controller(owning: tab)?.detach(tab)
        let controller = TerminalController(ghostty, adopting: tab)
        controller.isBackgroundOpaque = inheritBackgroundOpacity
        controller.showWindowSafely(nil)

        // With native tabs the window owns the color, so it has to come off the
        // tab. With our own tabs the window reads it back off the tab and this
        // writes the value it already holds. Doing it here rather than at each
        // call site is what makes tearing a tab off keep its color when the
        // option was turned off after the color was set.
        (controller.window as? TerminalWindow)?.tabColor = tab.tabColor
        controller.scheduleInitialPresentation {
            guard let window = controller.window else { return }
            if let frame {
                window.setFrame(frame, display: true)
                return
            }
            if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                window.setContentSize(treeSize)
                window.constrainToScreen()
            }
            if !window.styleMask.contains(.fullScreen) {
                if let position {
                    window.setFrameTopLeftPoint(position)
                    window.constrainToScreen()
                } else {
                    let hasFixedPos = controller.derivedConfig.windowPositionX != nil &&
                        controller.derivedConfig.windowPositionY != nil
                    Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }
        }
        return controller
    }

    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        // With non-native tabs the tab lives inside the parent's window, so there is
        // no new window, no tab group, and none of the AppKit dance below.
        if parentController.usesNonNativeTabs {
            if parent.isMiniaturized { parent.deminiaturize(self) }
            guard let tab = parentController.addTab(
                baseConfig: baseConfig,
                at: parentController.newTabIndex
            ) else { return nil }
            // The parent window is already on screen, so it only has to come
            // forward. `showWindow` would re-run the initial placement in our
            // override above and snap a moved window back to its configured
            // position. The native path below shows a window for the first
            // time, which is a different thing.
            parent.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            if let undoManager = parentController.undoManager {
                undoManager.setActionName("New Tab")
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: parentController.undoExpiration
                ) { ghostty in
                    guard let target = TerminalController.controller(owning: tab) else { return }
                    let parent = target.window

                    // The tab may hold a running process, so this can put a
                    // sheet up and finish later. We still register the redo
                    // right here: anything registered after this closure
                    // returns lands on the undo stack instead of the redo
                    // stack. The native path below does the same.
                    target.closeTab(tab, registerUndo: false)

                    undoManager.registerUndo(
                        withTarget: ghostty,
                        expiresAfter: target.undoExpiration
                    ) { ghostty in
                        _ = TerminalController.newTab(
                            ghostty,
                            from: parent,
                            withBaseConfig: baseConfig)
                    }
                }
            }

            return parentController
        }

        // If our parent is in non-native fullscreen, then new tabs do not work.
        // See: https://github.com/mitchellh/ghostty/issues/392
        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(ghostty, withBaseConfig: baseConfig)
        controller.isBackgroundOpaque = parentController.isBackgroundOpaque
        guard let window = controller.window else { return controller }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup,
           tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // If we don't allow tabs then we create a new window instead.
        if window.tabbingMode != .disallowed {
            let tabCreated: Bool
            // Add the window to the tab group and show it.
            switch ghostty.config.windowNewTabPosition {
            case "end":
                // If we already have a tab group and we want the new tab to open at the end,
                // then we use the last window in the tab group as the parent.
                if let last = parent.tabGroup?.windows.last {
                    tabCreated = last.addTabbedWindowSafely(window, ordered: .above)
                } else {
                    fallthrough
                }

            case "current": fallthrough
            default:
                tabCreated = parent.addTabbedWindowSafely(window, ordered: .above)
            }
            if tabCreated {
                // We set the selectedWindow early here because we want the next window
                // to become first responder as quickly as possible. Usually this is
                // set while `-[NSWindowController showWindow:]` is called, but we're
                // dispatching it to resolve other issues.
                parent.tabGroup?.selectedWindow = window
            }
        }

        // showWindow makes regular windows key and ordered front. AppKit can
        // throw while selecting a tab if its fullscreen stack is inconsistent,
        // so this must cross the Objective-C exception bridge.
        // We don't need to dispatch this because `tabbingMode = .disallowed`
        // for HiddenTitlebarTerminalWindow.
        controller.showWindowSafely(self)

        // Windows with `macos-titlebar-style = hidden` create new windows when the
        // new tab binding is pressed, we should cascade those windows as well.

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect after position in `showWindow`. Our best theory is there is some
        // next-event-loop-tick logic that Cocoa is doing that we need to be after.
        controller.scheduleInitialPresentation {
            // Only cascade if we aren't fullscreen and are alone in the tab group.
            if !window.styleMask.contains(.fullScreen) &&
                window.tabGroup?.windows.count ?? 1 == 1 {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil && controller.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            // We also activate our app so that it becomes front. This may be
            // necessary for the dock menu.
            NSApp.activate(ignoringOtherApps: true)
        }

        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
        }

        // Setup our undo
        if let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                // Close the tab when undoing
                undoManager.disableUndoRegistration {
                    target.closeTab(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newTab(
                        ghostty,
                        from: parent,
                        withBaseConfig: baseConfig)
                }
            }
        }

        return controller
    }

    // MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if notification.object == nil {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // `window-show-tab-bar` decides whether our own bar is installed at
            // all, so a reload has to act on it.
            syncTabBarVisibility()

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
        /// Surface-level config will be updated in
        /// ``Ghostty/Ghostty/SurfaceView/derivedConfig`` then
        /// ``TerminalController/focusedSurfaceDidChange(to:)``
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // With non-native tabs there is no tab group to label. Our own bar draws
        // the same `goto_tab:N` shortcuts, so push them there instead.
        if usesNonNativeTabs {
            tabBarAccessory?.refreshShortcuts()
            return
        }

        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = window?.tabbedWindows?.count ?? 0 > 1

        if let windows = window?.tabbedWindows as? [TerminalWindow] {
            for (tab, window) in zip(1..., windows) {
                // We need to clear any windows beyond this because they have had
                // a keyEquivalent set previously.
                guard tab <= 9 else {
                    window.keyEquivalent = ""
                    continue
                }

                if let equiv = ghostty.config.keyboardShortcut(for: "goto_tab:\(tab)") {
                    window.keyEquivalent = "\(equiv)"
                } else {
                    window.keyEquivalent = ""
                }
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // The tab bar draws in terminal colors, not system colors, so it has to
        // be resynced alongside the window whenever those change.
        if let tabBarAccessory {
            tabBarAccessory.update(
                backgroundColor: window.preferredBackgroundColor ?? .windowBackgroundColor,
                font: window.titlebarFont.map { Font($0) } ?? .system(size: 12))
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// Close a tab and everything in it, with no confirmation.
    ///
    /// With no `tab` this closes the active one. `neighbor` is the tab an undo
    /// should look for the window by; see `TabUndoLocation`.
    func closeTabImmediately(
        _ tab: TerminalTab? = nil,
        registerUndo: Bool = true,
        registerRedo: Bool = true,
        neighbor: TerminalTab? = nil
    ) {
        guard let tab = tab ?? activeTab,
              let owner = Self.controller(owning: tab) else { return }
        if owner !== self {
            owner.closeTabImmediately(
                tab,
                registerUndo: registerUndo,
                registerRedo: registerRedo,
                neighbor: neighbor)
            return
        }

        guard let window = window else { return }

        if usesNonNativeTabs {
            guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

            // The last tab means the window goes with it.
            guard tabs.count > 1 else {
                closeWindowImmediately(registerUndo: registerUndo)
                return
            }

            let location = TabUndoLocation(
                controller: self, tab: tab, index: index, neighbor: neighbor)
            let ghostty = self.ghostty
            removeTab(at: index)

            if let undoManager, registerUndo {
                undoManager.setActionName("Close Tab")
                // The closure is what keeps the tab, and every surface in it,
                // alive until the undo expires.
                undoManager.registerUndo(
                    withTarget: tab,
                    expiresAfter: undoExpiration
                ) { [tab] _ in
                    let target = location.restore(tab, ghostty: ghostty)

                    if registerRedo {
                        undoManager.registerUndo(
                            withTarget: tab,
                            expiresAfter: target.undoExpiration
                        ) { [tab] _ in
                            Self.controller(owning: tab)?.closeTabImmediately(tab)
                        }
                    }
                }
            }

            return
        }

        guard let tabGroup = window.tabGroup,
                tabGroup.windows.count > 1 else {
            closeWindowImmediately(registerUndo: registerUndo)
            return
        }

        cancelPendingInitialPresentation()

        // Undo
        if let undoManager, let undoState, registerUndo {
            // Register undo action to restore the tab
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { ghostty in
                let newController = TerminalController(ghostty, with: undoState)

                if registerRedo {
                    undoManager.registerUndo(
                        withTarget: newController,
                        expiresAfter: newController.undoExpiration
                    ) { target in
                        target.closeTabImmediately()
                    }
                }
            }
        }

        window.close()
    }

    private func closeOtherTabsImmediately(keeping keep: TerminalTab? = nil) {
        guard let window = window else { return }

        let kept = usesNonNativeTabs ? (keep ?? activeTab) : nil
        let closeOthers: () -> Void
        if usesNonNativeTabs {
            guard tabs.count > 1, let kept else { return }
            closeOthers = { [self] in
                // From the back so each tab's undo restores it at the index it
                // actually had.
                for tab in tabs.reversed() where tab !== kept {
                    closeTabImmediately(tab, registerRedo: false, neighbor: kept)
                }
            }
        } else {
            guard let tabGroup = window.tabGroup else { return }
            guard tabGroup.windows.count > 1 else { return }
            closeOthers = { [self] in
                // Iterate through all tabs except the current one.
                for window in tabGroup.windows where window != self.window {
                    // We ignore any non-terminal tabs. They don't currently exist and we can't
                    // properly undo them anyways so I'd rather ignore them and get a bug report
                    // later if and when we introduce non-terminal tabs.
                    if let controller = window.windowController as? TerminalController {
                        // We must not register a redo, because it messes with our own redo
                        // that we register later.
                        controller.closeTabImmediately(registerRedo: false)
                    }
                }
            }
        }

        // Start an undo grouping
        if let undoManager {
            undoManager.beginUndoGrouping()
        }
        defer {
            undoManager?.endUndoGrouping()
        }

        closeOthers()

        if let undoManager {
            undoManager.setActionName("Close Other Tabs")

            // We need to register an undo that refocuses this window. Otherwise, the
            // undo operation above for each tab will steal focus.
            //
            // Against the kept tab rather than against us, because the window
            // may be gone by the time this runs and `windowWillClose` drops
            // everything registered against a controller. The tab outlives it.
            let undoExpiration = self.undoExpiration
            if let kept {
                undoManager.registerUndo(
                    withTarget: kept,
                    expiresAfter: undoExpiration
                ) { [kept] _ in
                    DispatchQueue.main.async {
                        guard let owner = Self.controller(owning: kept) else { return }
                        owner.window?.makeKeyAndOrderFront(nil)

                        // Each tab took the selection as it came back, so put
                        // it back on the one the user kept.
                        owner.selectTab(kept)
                    }

                    undoManager.registerUndo(
                        withTarget: kept,
                        expiresAfter: undoExpiration
                    ) { [kept] _ in
                        Self.controller(owning: kept)?.closeOtherTabsImmediately(keeping: kept)
                    }
                }
            } else {
                undoManager.registerUndo(
                    withTarget: self,
                    expiresAfter: undoExpiration
                ) { target in
                    DispatchQueue.main.async {
                        target.window?.makeKeyAndOrderFront(nil)
                    }

                    // Register redo action
                    undoManager.registerUndo(
                        withTarget: target,
                        expiresAfter: target.undoExpiration
                    ) { target in
                        target.closeOtherTabsImmediately()
                    }
                }
            }
        }
    }

    private func closeTabsOnTheRightImmediately(after keep: TerminalTab? = nil) {
        guard let window = window else { return }

        let kept = usesNonNativeTabs ? (keep ?? activeTab) : nil
        let closeToTheRight: () -> Void
        if usesNonNativeTabs {
            guard let kept, let from = tabs.firstIndex(where: { $0 === kept }) else { return }
            let toClose = tabs.enumerated().filter { $0.offset > from }.map(\.element)
            guard !toClose.isEmpty else { return }
            closeToTheRight = { [self] in
                // From the back so each tab's undo restores it at the index it
                // actually had.
                for tab in toClose.reversed() {
                    closeTabImmediately(tab, registerRedo: false, neighbor: kept)
                }
            }
        } else {
            guard let tabGroup = window.tabGroup else { return }
            guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

            let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
            guard !tabsToClose.isEmpty else { return }
            closeToTheRight = {
                for (_, candidate) in tabsToClose {
                    if let controller = candidate.windowController as? TerminalController {
                        controller.closeTabImmediately(registerRedo: false)
                    }
                }
            }
        }

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
        }

        closeToTheRight()

        if let undoManager {
            undoManager.setActionName("Close Tabs to the Right")

            // Same as "Close Other Tabs": the restored tabs take the selection
            // on the way back, and the tab outlives the window this was
            // started from.
            let undoExpiration = self.undoExpiration
            if let kept {
                undoManager.registerUndo(
                    withTarget: kept,
                    expiresAfter: undoExpiration
                ) { [kept] _ in
                    DispatchQueue.main.async {
                        guard let owner = Self.controller(owning: kept) else { return }
                        owner.window?.makeKeyAndOrderFront(nil)
                        owner.selectTab(kept)
                    }

                    undoManager.registerUndo(
                        withTarget: kept,
                        expiresAfter: undoExpiration
                    ) { [kept] _ in
                        Self.controller(owning: kept)?.closeTabsOnTheRightImmediately(after: kept)
                    }
                }
            } else {
                undoManager.registerUndo(
                    withTarget: self,
                    expiresAfter: undoExpiration
                ) { target in
                    DispatchQueue.main.async {
                        target.window?.makeKeyAndOrderFront(nil)
                    }

                    undoManager.registerUndo(
                        withTarget: target,
                        expiresAfter: target.undoExpiration
                    ) { target in
                        target.closeTabsOnTheRightImmediately()
                    }
                }
            }
        }
    }

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
    func closeWindowImmediately(registerUndo: Bool = true) {
        guard let window = window else { return }

        cancelPendingInitialPresentation()

        if registerUndo {
            registerUndoForCloseWindow()
        }

        if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
            tabGroup.windows.forEach { window in
                // Clear out the surfacetree to ensure there is no undo state.
                // This prevents unnecessary undos registered since AppKit may
                // process them on later ticks so we can't just disable undo registration.
                if let controller = window.windowController as? TerminalController {
                    controller.cancelPendingInitialPresentation()
                    controller.releaseTabs()
                    controller.surfaceTree = .init()
                }

                window.close()
            }
        } else {
            window.close()
        }
    }

    /// Registers undo for closing window(s), handling both single windows and tab groups.
    private func registerUndoForCloseWindow() {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        guard let window else { return }

        // If we don't have a tab group or we don't have multiple tabs, then
        // do a normal single window close.
        guard let tabGroup = window.tabGroup,
              tabGroup.windows.count > 1 else {
            // No tabs, just save this window's state
            if let undoState {
                // Register undo action to restore the window
                undoManager.setActionName("Close Window")
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: undoExpiration) { ghostty in
                        // Restore the undo state
                        let newController = TerminalController(ghostty, with: undoState)

                        // Register redo action
                        undoManager.registerUndo(
                            withTarget: newController,
                            expiresAfter: newController.undoExpiration) { target in
                                target.closeWindowImmediately()
                            }
                    }
            }

            return
        }

        // Multiple windows in tab group - collect all undo states in sorted order
        // by tab ordering. Also track which window was key.
        let undoStates = tabGroup.windows
            .compactMap { tabWindow -> UndoState? in
                guard let controller = tabWindow.windowController as? TerminalController,
                      var undoState = controller.undoState else { return nil }
                // Clear the tab group reference since it is unneeded. It should be
                // garbage collected but we want to be extra sure we don't try to
                // restore into it because we're going to recreate it.
                undoState.tabGroup = nil
                return undoState
            }
            .sorted { (lhs, rhs) in
                switch (lhs.tabIndex, rhs.tabIndex) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return true
                }
            }

        // Find the index of the key window in our sorted states. This is a bit verbose
        // but we only need this for this style of undo so we don't want to add it to
        // UndoState.
        let keyWindowIndex: Int?
        if let keyWindow = tabGroup.windows.first(where: { $0.isKeyWindow }),
            let keyController = keyWindow.windowController as? TerminalController,
            let keyUndoState = keyController.undoState {
            keyWindowIndex = undoStates.firstIndex {
                $0.tabIndex == keyUndoState.tabIndex }
        } else {
            keyWindowIndex = nil
        }

        // Register undo action to restore all windows
        guard !undoStates.isEmpty else { return }

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: undoExpiration
        ) { ghostty in
            // Restore all windows in the tab group
            let controllers = undoStates.map { undoState in
                TerminalController(ghostty, with: undoState)
            }

            // The first controller becomes the parent window for all tabs.
            // If we don't have a first controller (shouldn't be possible?)
            // then we can't restore tabs.
            guard let firstController = controllers.first else { return }

            // Add all subsequent controllers as tabs to the first window
            for controller in controllers.dropFirst() {
                controller.showWindow(nil)
                if let firstWindow = firstController.window,
                   let newWindow = controller.window {
                    firstWindow.addTabbedWindowSafely(newWindow, ordered: .above)
                }
            }

            // Make the appropriate window key. If we had a key window, restore it.
            // Otherwise, make the last window key.
            if let keyWindowIndex, keyWindowIndex < controllers.count {
                controllers[keyWindowIndex].window?.makeKeyAndOrderFront(nil)
            } else {
                controllers.last?.window?.makeKeyAndOrderFront(nil)
            }

            // Register redo action on the first controller
            undoManager.registerUndo(
                withTarget: firstController,
                expiresAfter: firstController.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The window we use for confirmations. Try to find the first window that
        // needs quit confirmation. This lets us attach the confirmation to something
        // that is running.
        // A surface in a background tab has no window of its own, so fall back
        // to the window that holds it.
        guard let confirmWindow = all
            .first(where: { $0.allSurfaces.contains(where: { $0.needsConfirmQuit }) })
            .flatMap({ controller in
                controller.allSurfaces.first(where: { $0.needsConfirmQuit })?.window ?? controller.window
            })
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let tabIndex: Int?
        weak var tabGroup: NSWindowTabGroup?
        let isBackgroundOpaque: Bool

        /// With native tabs the window owns its color rather than the tab, so
        /// retaining the tabs is not enough to bring it back.
        let tabColor: TerminalTabColor

        /// We retain the original tabs so earlier undos can still find them.
        let tabs: [TerminalTab]
        let activeTabIndex: Int
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        let active = undoState.tabs[undoState.activeTabIndex]
        self.init(ghostty, adopting: active)
        isBackgroundOpaque = undoState.isBackgroundOpaque
        (window as? TerminalWindow)?.tabColor = undoState.tabColor

        var previousWindow = window
        for (index, tab) in undoState.tabs.enumerated() where index != undoState.activeTabIndex {
            if usesNonNativeTabs {
                insert(tab, at: index)
            } else {
                // The tab mode may have changed while the window was closed.
                // We still adopt the original objects in their native windows.
                let restored = TerminalController(ghostty, adopting: tab)
                restored.isBackgroundOpaque = isBackgroundOpaque

                // Native tabs keep the color on the window, so it has to come
                // off the tab and onto the window we just gave it.
                (restored.window as? TerminalWindow)?.tabColor = tab.tabColor
                let parent = index < undoState.activeTabIndex ? window : previousWindow
                if let parent, let newWindow = restored.window {
                    let attached = parent.addTabbedWindowSafely(
                        newWindow, ordered: index < undoState.activeTabIndex ? .below : .above)
                    if attached, index > undoState.activeTabIndex { previousWindow = newWindow }
                }
                restored.showWindowSafely(nil)
            }
        }
        if usesNonNativeTabs {
            selectTab(active)
        } else {
            window?.tabGroup?.selectedWindow = window
        }

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    currentWindow.addTabbedWindowSafely(window, ordered: .below)
                } else {
                    tabGroup.windows.last?.addTabbedWindowSafely(window, ordered: .above)
                }

                // Make it the key window
                window.makeKeyAndOrderFront(nil)
            }

            // Restore focus to the previously focused surface
            if let focusTarget = active.focusedSurface, surfaceTree.contains(focusTarget) {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusTarget, from: nil)
                }
            } else if let focusedSurface = surfaceTree.first {
                // No prior focused surface or we can't find it, let's focus
                // the first.
                self.focusedSurface = focusedSurface
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusedSurface, from: nil)
                }
            }
        }
    }

    /// Open a saved tab as a native tab, for when the option was turned off
    /// since it was saved. If AppKit won't attach the window we leave it as a
    /// session of its own rather than dropping it.
    func restoreNativeTab(
        tree: SplitTree<Ghostty.SurfaceView>,
        titleOverride: String?,
        tabColor: TerminalTabColor?,
        focusedSurface: UUID?,
        relativeTo parent: NSWindow?,
        ordered: NSWindow.OrderingMode
    ) -> NSWindow? {
        let controller = TerminalController(ghostty, withSurfaceTree: tree)
        controller.isBackgroundOpaque = isBackgroundOpaque
        controller.titleOverride = titleOverride
        if let tabColor {
            (controller.window as? TerminalWindow)?.tabColor = tabColor
        }
        if let focusedSurface {
            controller.focusedSurface = tree.first { $0.id == focusedSurface }
        }
        let attached: Bool
        if let parent, let window = controller.window {
            attached = parent.addTabbedWindowSafely(window, ordered: ordered)
        } else {
            attached = false
        }
        controller.showWindowSafely(nil)
        return attached ? controller.window : nil
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard let activeTab, !activeTab.surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup,
            isBackgroundOpaque: isBackgroundOpaque,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none,
            tabs: tabs,
            activeTabIndex: activeTabIndex)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // If we draw our own tabs, AppKit must never put this window into a tab
        // group. This has to happen before anything can materialize the group.
        if usesNonNativeTabs {
            window.tabbingMode = .disallowed
        }

        // Setting all three of these is required for restoration to work.
        syncWindowRestorability()

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }

        // Set the initial content size on the container so that
        // intrinsicContentSize returns the correct value immediately,
        // without waiting for @FocusedValue to propagate through the
        // SwiftUI focus chain.
        container.initialContentSize = focusedSurface?.initialSize

        window.contentView = container

        // Install our own tab bar when we own the tabs. The bar carries the
        // session name, so the centered window title is redundant.
        if usesNonNativeTabs {
            syncTabBarVisibility()
            $tabs
                .map(\.count)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncTabBarVisibility() }
                .store(in: &tabBarCancellables)
        }

        // If we have a default size, we want to apply it.
        if let defaultSize {
            defaultSize.apply(to: window)

            if case .contentIntrinsicSize = defaultSize {
                if let screen = window.screen ?? NSScreen.main {
                    let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                    window.setFrameOrigin(frame.origin)
                }
            }
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        //
        // We also only run this when the system tabbing preference is "always",
        // which is the only scenario AppKit will have auto-tabbed a fresh window
        // at this point: the tab bar "+" button goes through newWindowForTab
        // which we route through our own tab logic. This check matters because
        // accessing `window.tabGroup` materializes the window's tab group
        // machinery, which takes ~15-20ms and is otherwise not needed during
        // window creation.
        if NSWindow.userTabbingPreference == .always,
           !window.styleMask.contains(.fullScreen) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard let terminalWindow = window as? TerminalWindow else { return }

        // Set the initial window position. This must happen after the window
        // is fully set up (content view, toolbar, default size) so that
        // decorations added by subclass awakeFromNib (e.g. toolbar for tabs
        // style) don't change the frame after the position is restored.
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: defaultSize == nil,
        )

        // If nothing is changed for the frame,
        // we should center the window
        if !originChanged, !restored {
            // This doesn't work in `windowDidLoad` somehow
            terminalWindow.center()
        }

        super.showWindow(sender)

        syncAppearance()
    }

    override func fullscreenDidChange() {
        super.fullscreenDidChange()

        // Tab count or visibility may have changed while the titlebar was absent.
        syncTabBarVisibility()
    }

    /// Move a tab out into a window of its own.
    ///
    /// This is what AppKit's `moveTabToNewWindow:` does for native tabs. That
    /// selector is disabled without a tab group, so with non-native tabs the Window
    /// menu item and the tab context menu come here instead.
    func moveTabToNewWindow(_ tab: TerminalTab, position: NSPoint? = nil) {
        guard usesNonNativeTabs, tabs.count > 1,
              let index = tabs.firstIndex(where: { $0 === tab }) else { return }

        let location = TabUndoLocation(controller: self, tab: tab, index: index)
        let created = TerminalController.newWindow(
            ghostty,
            adopting: tab,
            position: position,
            inheritBackgroundOpacity: isBackgroundOpaque)
        created.registerUndoForTabMove(tab, to: location, action: "Move Tab to New Window")
    }

    /// Install or remove the tab bar per `window-show-tab-bar`.
    ///
    /// The accessory is added and removed rather than hidden: an
    /// `NSTitlebarAccessoryViewController` marked `isHidden` still occupies the
    /// titlebar. When the bar is down the window title is the only thing naming
    /// the session, so it comes back; when the bar is up the centered title
    /// would only repeat what the active tab already says.
    private func syncTabBarVisibility() {
        guard usesNonNativeTabs, let window,
              window.styleMask.contains(.titled) else { return }

        let visible: Bool
        switch derivedConfig.windowShowTabBar {
        case .always: visible = true
        case .auto: visible = tabs.count > 1
        case .never: visible = false
        }

        if visible {
            let accessory = tabBarAccessory ?? TerminalTabBarAccessoryViewController(controller: self)
            tabBarAccessory = accessory

            // Reconcile against the window rather than our own record. Taking
            // `titled` out of the style mask and putting it back, which
            // non-native fullscreen does, drops every accessory the window had.
            if !window.titlebarAccessoryViewControllers.contains(accessory) {
                window.addTitlebarAccessoryViewController(accessory)
                syncAppearance()
            }
        } else {
            if let accessory = tabBarAccessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            tabBarAccessory = nil
        }

        // The bar sits where the title would, and names the session better, so
        // the two swap. Each titlebar style knows where its own title lives.
        if derivedConfig.macosTitlebarStyle == .tabs {
            (window as? TerminalWindow)?.setTitleHiddenForTabBar(visible)
        }
    }

    /// Pull every other Ghostty-tabbed window's tabs into this one.
    ///
    /// AppKit's "Merge All Windows" works on tab groups, which don't exist
    /// here, so this is the equivalent for non-native tabs. Windows using native
    /// tabs are left alone: merging those would mean changing their tab style.
    func mergeAllWindows() {
        guard usesNonNativeTabs else { return }

        let others = NSApp.windows
            .compactMap { $0.windowController as? TerminalController }
            .filter { $0 !== self && $0.usesNonNativeTabs }
        guard !others.isEmpty else { return }

        // Merging is not undoable with native tabs either, so there is nothing
        // to register here.
        let selected = activeTab
        for other in others {
            for tab in other.tabs {
                other.detach(tab)
                insert(tab, at: tabs.count)
            }
        }

        // Every insert selects what it inserted, so put the selection back on
        // the tab the user was actually looking at.
        if let selected { selectTab(selected) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Window menu items for the two tab commands AppKit only offers when it
    /// owns the tabs. They're hidden entirely with native tabs,
    /// where AppKit injects its own into this same menu.
    @IBAction func moveGhosttyTabToNewWindow(_ sender: Any?) {
        guard let activeTab else { return }
        moveTabToNewWindow(activeTab)
    }

    @IBAction func mergeAllGhosttyWindows(_ sender: Any?) {
        mergeAllWindows()
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    // MARK: NSWindowDelegate

    // TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self else { return }
            switch scope {
            case .tab: closeTab(nil)
            case .window:
                guard self.window?.isFirstWindowInTabGroup ?? false else { return }
                closeWindow(nil)
            }
        }

        // We will always explicitly close the window using the above
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        releaseTabs()
        cancelPendingInitialPresentation()
        self.relabelTabs()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        self.fixTabBar()

        // Whenever we move save our last position for the next start.
        LastWindowPosition.shared.save(window)
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        // Whenever we resize save our last position and size for the next start.
        LastWindowPosition.shared.save(window)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        LastWindowPosition.shared.save(window)

        // Remember our last main
        Self.lastMain = self
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        closeTab(registerUndo: true)
    }

    /// Close the tab on screen, confirming first if it is still running.
    ///
    /// `registerUndo` is carried rather than wrapped in
    /// `disableUndoRegistration`, because a confirmation finishes on a later
    /// turn, by which time registration is enabled again.
    func closeTab(registerUndo: Bool) {
        guard let window = window else { return }

        // With our own tabs the confirmation finishes on a later turn, and the
        // active tab can change while the sheet is up: a background process
        // exiting shifts the index. Bind to the tab on screen now and let the
        // per-tab path do the rest, so what we close is what we asked about.
        // That path hands native windows straight back here, so this does not
        // recurse.
        if usesNonNativeTabs {
            guard let tab = activeTab else { return }
            closeTab(tab, registerUndo: registerUndo)
            return
        }

        guard (window.tabGroup?.windows.count ?? 0) > 1 else {
            closeWindow(registerUndo: registerUndo)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately(registerUndo: registerUndo)
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately(registerUndo: registerUndo)
        }
    }

    /// Close a specific tab, confirming first if it has a running process.
    ///
    /// `registerUndo` is false when undoing "New Tab": the tab going away is
    /// the undo, not a new thing to undo.
    func closeTab(_ tab: TerminalTab, registerUndo: Bool = true) {
        guard tabs.contains(where: { $0 === tab }) else { return }

        // The tab may have moved into a window using native tabs since we were
        // given it. That path owns its own confirmation, so hand it over.
        guard usesNonNativeTabs else {
            closeTab(registerUndo: registerUndo)
            return
        }

        // Closing the only tab closes the window.
        guard tabs.count > 1 else {
            closeWindow(registerUndo: registerUndo)
            return
        }

        let close = { [weak self] in
            self?.closeTabImmediately(tab, registerUndo: registerUndo)
        }

        guard tab.surfaces.contains(where: { $0.needsConfirmQuit }) else {
            close()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            close()
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        closeOtherTabs(keeping: activeTab)
    }

    /// Close every tab but one. The menu item means the tab on screen; an
    /// action targeting a surface means the tab that surface is in.
    func closeOtherTabs(keeping keep: TerminalTab?) {
        guard let window = window else { return }

        if usesNonNativeTabs {
            guard tabs.count > 1, let keep else { return }

            let others = tabs.filter { $0 !== keep }
            guard others.contains(where: { $0.surfaces.contains { $0.needsConfirmQuit } }) else {
                closeOtherTabsImmediately(keeping: keep)
                return
            }

            confirmClose(
                messageText: "Close Other Tabs?",
                informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
            ) {
                self.closeOtherTabsImmediately(keeping: keep)
            }
            return
        }

        guard let tabGroup = window.tabGroup else { return }

        // If we only have one window then we have no other tabs to close
        guard tabGroup.windows.count > 1 else { return }

        // Check if we have to confirm close.
        guard tabGroup.windows.contains(where: { window in
            // Ignore ourself
            if window == self.window { return false }

            // Ignore non-terminals
            guard let controller = window.windowController as? TerminalController else {
                return false
            }

            // Check if any surfaces require confirmation
            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }) else {
            self.closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        closeTabsOnTheRight(after: activeTab)
    }

    /// Close every tab after one. The menu item means the tab on screen; an
    /// action targeting a surface means the tab that surface is in.
    func closeTabsOnTheRight(after keep: TerminalTab?) {
        guard let window = window else { return }

        if usesNonNativeTabs {
            guard let keep, let from = tabs.firstIndex(where: { $0 === keep }) else { return }
            let toClose = tabs.enumerated().filter { $0.offset > from }
            guard !toClose.isEmpty else { return }

            guard toClose.contains(where: { $0.element.surfaces.contains { $0.needsConfirmQuit } }) else {
                closeTabsOnTheRightImmediately(after: keep)
                return
            }

            confirmClose(
                messageText: "Close Tabs on the Right?",
                informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
            ) {
                self.closeTabsOnTheRightImmediately(after: keep)
            }
            return
        }

        guard let tabGroup = window.tabGroup else { return }
        guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

        let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { (_, candidate) in
            guard let controller = candidate.windowController as? TerminalController else {
                return false
            }

            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        closeWindow(registerUndo: true)
    }

    /// Close this window, confirming first if anything in it is still running.
    ///
    /// `registerUndo` has to be carried rather than wrapped in
    /// `disableUndoRegistration`, because a confirmation finishes on a later
    /// turn, by which time registration is enabled again.
    func closeWindow(registerUndo: Bool) {
        guard let window = window else { return }

        // We need to check all the windows in our tab group for confirmation
        // if we're closing the window. If we don't have a tabgroup for any
        // reason we check ourselves.
        let windows: [NSWindow] = window.tabGroup?.windows ?? [window]
        let confirmControllers = windows
            .compactMap({ $0.windowController as? TerminalController })
            // `allSurfaces` rather than `surfaceTree`: with non-native tabs a
            // process in a background tab is still about to be killed.
            .filter({ $0.allSurfaces.contains(where: { $0.needsConfirmQuit }) })
        guard
            !confirmControllers.isEmpty
        else {
            closeWindowImmediately(registerUndo: registerUndo)
            return
        }
        if confirmControllers.count == 1 {
            // We call confirmClose on the proper controller so the alert is
            // attached to the window that needs confirmation.
            confirmControllers[0].confirmClose(
                messageText: "Close Window?",
                informativeText: "All terminal sessions in this window will be terminated.",
            ) {
                self.closeWindowImmediately(registerUndo: registerUndo)
            }
            return
        }

        Task {
            let alert = NSAlert.reviewWindowsAlert(
                messageText: "You have \(confirmControllers.count) windows with running processes. Do you want to review these windows before closing?",
                terminateNowButtonTitle: "Close"
            )
            switch await alert.beginSheetModal(for: window) {
            case .alertFirstButtonReturn:
                await reviewWindows(
                    confirmControllers, window: window, registerUndo: registerUndo)
            case .alertSecondButtonReturn:
                closeWindowImmediately(registerUndo: registerUndo)
            default:
                break
            }
        }
    }

    private func reviewWindows(
        _ controllers: [TerminalController],
        window: NSWindow,
        registerUndo: Bool
    ) async {
        for controller in controllers {
            let response = await controller.confirmCloseAsync(
                messageText: "Close Window?",
                informativeText: "All terminal sessions in this window will be terminated.",
            )

            if [.OK, .alertFirstButtonReturn].contains(response) {
                // Close this tab
                controller.closeTabImmediately(registerUndo: registerUndo)
                continue
            } else {
                // Cancel the review
                return
            }
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    // MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        if usesNonNativeTabs {
            moveActiveTab(amount: action.amount)
            return
        }

        // Determine our current selected index
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        let tabbedWindows = tabGroup.windows
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = tabbedWindows.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        // Get our target window
        let targetWindow = tabbedWindows[finalIndex]

        // Moving tabs on macOS 26 RC causes very nasty visual glitches in the titlebar tabs.
        // I believe this is due to messed up constraints for our hacky tab bar. I'd like to
        // find a better workaround. For now, this improves things dramatically.
        //
        // Reproduction: titlebar tabs, create two tabs, "move tab left"
        if #available(macOS 26, *) {
            if window is TitlebarTabsTahoeTerminalWindow {
                tabGroup.removeWindow(selectedWindow)
                targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)
                DispatchQueue.main.async {
                    selectedWindow.makeKey()
                }

                return
            }
        }

        // Begin a group of window operations to minimize visual updates
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        // Remove and re-add the window in the correct position
        tabGroup.removeWindow(selectedWindow)
        targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)

        // Ensure our window remains selected
        selectedWindow.makeKey()

        NSAnimationContext.endGrouping()
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        if usesNonNativeTabs {
            gotoNonNativeTab(tabIndex)
            return
        }

        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if tabIndex <= 0 {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                if selectedIndex == 0 {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                if selectedIndex == tabbedWindows.count - 1 {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                finalIndex = tabbedWindows.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), tabbedWindows.count - 1)
        }

        guard finalIndex >= 0 else { return }
        let targetWindow = tabbedWindows[finalIndex]
        targetWindow.makeKeyAndOrderFront(nil)
    }

    /// `goto_tab` for non-native tabs. Mirrors the native branch above: values <= 0
    /// are the previous/next/last sentinels, positive values are 1-indexed and
    /// clamp to the last tab.
    private func gotoNonNativeTab(_ tabIndex: Int32) {
        guard tabs.count > 0 else { return }

        if tabIndex <= 0 {
            switch tabIndex {
            case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
                selectTab(offset: -1)
            case GHOSTTY_GOTO_TAB_NEXT.rawValue:
                selectTab(offset: 1)
            case GHOSTTY_GOTO_TAB_LAST.rawValue:
                selectTab(at: tabs.count - 1)
            default:
                return
            }
            return
        }

        selectTab(at: min(Int(tabIndex - 1), tabs.count - 1))
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }

        // The action names a surface, so it names that surface's tab rather
        // than whichever one we happen to be showing.
        guard let tab = tab(owning: target) else { return }
        closeTab(tab)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard owns(target) else { return }

        // "Other" is relative to the tab the action named, which is not
        // necessarily the one we're showing. AppleScript can target either.
        closeOtherTabs(keeping: tab(owning: target) ?? activeTab)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard owns(target) else { return }
        closeTabsOnTheRight(after: tab(owning: target) ?? activeTab)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard owns(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard owns(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let windowShowTabBar: Ghostty.Config.WindowShowTabBar
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.windowShowTabBar = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.windowShowTabBar = config.windowShowTabBar
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: Tabs

extension TerminalController {
    /// The tab whose content is currently displayed.
    var activeTab: TerminalTab? {
        tabs[safe: activeTabIndex]
    }

    /// Finds the controller currently holding the given tab.
    static func controller(owning tab: TerminalTab) -> TerminalController? {
        if let controller = tabControllers.object(forKey: tab),
           controller.tabs.contains(where: { $0 === tab }) {
            return controller
        }

        return NSApp.windows
            .compactMap { $0.windowController as? TerminalController }
            .first { $0.tabs.contains { $0 === tab } }
    }

    /// The tab in this window that owns the given surface, if any.
    func tab(owning surface: Ghostty.SurfaceView) -> TerminalTab? {
        tabs.first { $0.surfaceTree.contains(surface) }
    }

    /// The tab in this window that owns the given split node, if any.
    func tab(owning node: SplitTree<Ghostty.SurfaceView>.Node) -> TerminalTab? {
        tabs.first { $0.surfaceTree.contains(node) }
    }

    /// Where a newly created tab belongs, per `window-new-tab-position`.
    ///
    /// This mirrors what the native path does with `addTabbedWindowSafely`:
    /// `end` appends to the window, anything else opens beside the tab the new
    /// one was created from.
    var newTabIndex: Int {
        switch ghostty.config.windowNewTabPosition {
        case "end": return tabs.count
        default: return activeTabIndex + 1
        }
    }

    /// Create a new tab holding a fresh surface, and select it.
    ///
    /// `index` is where to insert; nil appends.
    @discardableResult
    func addTab(
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        at index: Int? = nil
    ) -> TerminalTab? {
        guard let app = ghostty.app else { return nil }
        return addTab(
            surfaceTree: .init(view: Ghostty.SurfaceView(app, baseConfig: baseConfig)),
            at: index,
            restorable: (baseConfig?.command ?? "") == "")
    }

    /// Add an existing split tree as a new tab, and select it.
    @discardableResult
    func addTab(
        surfaceTree tree: SplitTree<Ghostty.SurfaceView>,
        at index: Int? = nil,
        restorable: Bool = true
    ) -> TerminalTab? {
        guard !tree.isEmpty else { return nil }

        let tab = TerminalTab(surfaceTree: tree, restorable: restorable)
        let insertAt = min(max(index ?? tabs.count, 0), tabs.count)
        tabs.insert(tab, at: insertAt)

        // Keep the active index pointing at the same tab it did before.
        if insertAt <= activeTabIndex { activeTabIndex += 1 }

        // Register ownership immediately: notifications from these surfaces can
        // arrive before the tab is ever selected.
        Self.tabControllers.setObject(self, forKey: tab)
        ownedTreeDidChange(from: .init(), to: tree)

        syncWindowRestorability()
        invalidateRestorableState()
        selectTab(at: insertAt)
        return tab
    }

    /// Keep AppKit's view of restorability in step with the tabs.
    ///
    /// Upstream can set this once in `windowDidLoad` because a window is a
    /// session there. Here adding or removing a tab can change the answer for
    /// the whole window, so every mutator calls this.
    private func syncWindowRestorability() {
        guard let window else { return }
        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        } else {
            window.restorationClass = nil
            window.identifier = nil
        }
    }

    /// Select the tab at the given index.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }

        // The outgoing tab needs no stashing: `surfaceTree` and `focusedSurface`
        // both write straight through to it as they change.
        activeTabIndex = index
        let incoming = tabs[index]

        // Attach the tree BEFORE asserting focus. `Ghostty.moveFocus` polls for
        // the target's `window` and silently gives up after 0.5s, so focusing a
        // surface that isn't in the hierarchy yet does nothing.
        surfaceTree = incoming.surfaceTree

        // Through the delegate method rather than by assigning `focusedSurface`,
        // because focus really has moved: the window title follows a
        // subscription to the focused surface, and the window's appearance is
        // taken from it. Assigning the property leaves both pointed at the tab
        // we just left.
        let target = incoming.focusedSurface ?? incoming.surfaces.first
        focusedSurfaceDidChange(to: target)
        if let target {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeTab === incoming else { return }
                Ghostty.moveFocus(to: target)
            }
        }

        activeTabDidChange()
    }

    /// Select a specific tab.
    func selectTab(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        selectTab(at: index)
    }

    /// Select the next or previous tab, wrapping around.
    func selectTab(offset: Int) {
        guard tabs.count > 1, offset != 0 else { return }
        let count = tabs.count
        let next = ((activeTabIndex + offset) % count + count) % count
        selectTab(at: next)
    }

    /// Remove the tab at the given index.
    ///
    /// Returns false when this was the last tab, in which case nothing is
    /// removed and the caller should close the window instead.
    @discardableResult
    func removeTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index), tabs.count > 1 else { return false }

        let removed = tabs[index]
        let wasActive = index == activeTabIndex
        tabs.remove(at: index)

        // Release after dropping the tab, so the ownership test we're releasing
        // against no longer counts the tab we just removed.
        if Self.tabControllers.object(forKey: removed) === self {
            Self.tabControllers.removeObject(forKey: removed)
        }
        if wasActive {
            // Fall to the tab that took this one's place, else the new last.
            // Swapping the displayed tree is what releases the surfaces we just
            // dropped, so there is nothing to do by hand here.
            let target = min(index, tabs.count - 1)
            // Force a reselect: activeTabIndex may already equal `target`.
            activeTabIndex = -1
            selectTab(at: target)
        } else {
            // Put the selection back on the tab that still holds it before
            // releasing anything, so nothing reads a stale index.
            if index < activeTabIndex { activeTabIndex -= 1 }
            ownedTreeDidChange(from: removed.surfaceTree, to: .init())
        }

        syncWindowRestorability()
        invalidateRestorableState()
        return true
    }

    /// Move the active tab by the given signed amount, bounded to the ends.
    func moveActiveTab(amount: Int) {
        guard tabs.count > 1, amount != 0 else { return }
        let from = activeTabIndex
        moveTab(
            from: from,
            to: Self.destination(movingFrom: from, by: amount, count: tabs.count))
    }

    /// Move any tab to a new position, keeping the selection on whichever tab
    /// held it. This is what a drag in the tab bar does.
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }

        let moved = Self.activeIndex(movingFrom: from, to: to, active: activeTabIndex)
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeTabIndex = moved

        activeTabDidChange()
        invalidateRestorableState()
    }

    /// Where the selection lands when the tab at `from` moves to `to`.
    ///
    /// The selected tab keeps the selection wherever it ends up; every other
    /// tab shifts by one only if the move crossed it.
    static func activeIndex(movingFrom from: Int, to: Int, active: Int) -> Int {
        if active == from { return to }
        if from < active && to >= active { return active - 1 }
        if from > active && to <= active { return active + 1 }
        return active
    }

    /// Where a tab at `from` lands when moved by a signed `amount` within a
    /// list of `count` tabs.
    ///
    /// The amount is bounded before it is added, never after: `move_tab` takes
    /// an `isize`, so `move_tab:9223372036854775807` is a legal binding and
    /// `from + amount` would trap on overflow. This is what the native path in
    /// `onMoveTab` does. Negative amounts are taken by magnitude because
    /// `-amount` traps for `Int.min`.
    static func destination(movingFrom from: Int, by amount: Int, count: Int) -> Int {
        if amount < 0 {
            return amount.magnitude >= UInt(from) ? 0 : from - Int(amount.magnitude)
        }
        return from + min(count - 1 - from, amount)
    }

    /// Insert an existing tab, taking it from whichever controller holds it.
    ///
    /// Within one window this is a reorder. Across windows the tab moves, and
    /// the window it came from closes if it was the last one there. The tab
    /// object itself moves, so its title override, color and focus come with
    /// it.
    func accept(_ tab: TerminalTab, at index: Int) {
        guard let source = Self.controller(owning: tab) else { return }

        if source === self {
            guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
            moveTab(from: from, to: min(max(index, 0), tabs.count - 1))
            return
        }

        guard let sourceIndex = source.tabs.firstIndex(where: { $0 === tab }) else { return }
        let sourceLocation = TabUndoLocation(controller: source, tab: tab, index: sourceIndex)
        source.detach(tab)
        insert(tab, at: index)
        registerUndoForTabMove(tab, to: sourceLocation, action: "Move Tab")
    }

    /// Where a tab goes back when we undo a move or close.
    /// We only keep the window's placement, not its other sessions.
    struct TabUndoLocation {
        weak var controller: TerminalController?
        weak var neighbor: TerminalTab?
        let index: Int

        /// Which side of `neighbor` the tab was on, since a window using native
        /// tabs can only be told to go before or after another one.
        let precedesNeighbor: Bool

        let frame: NSRect?
        let isBackgroundOpaque: Bool

        /// `neighbor` names the tab to find this one's window by later. It
        /// defaults to whichever other tab is first, which is right for closing
        /// one tab. A bulk close has to name the tab it kept: the others are
        /// going too, so anchoring to one of them would leave the restores
        /// looking for a window the redo has already left.
        init(
            controller: TerminalController,
            tab: TerminalTab,
            index: Int,
            neighbor: TerminalTab? = nil
        ) {
            let neighbor = neighbor ?? controller.tabs.first { $0 !== tab }
            self.controller = controller
            self.neighbor = neighbor
            self.index = index
            self.precedesNeighbor = neighbor
                .flatMap { other in controller.tabs.firstIndex { $0 === other } }
                .map { index < $0 } ?? false
            self.frame = controller.window?.frame
            self.isBackgroundOpaque = controller.isBackgroundOpaque
        }

        @discardableResult
        func restore(_ tab: TerminalTab, ghostty: Ghostty.App) -> TerminalController {
            // A restored window has a new controller. Find it through a tab
            // that stayed behind, if our original controller has closed.
            let destination = neighbor.flatMap { TerminalController.controller(owning: $0) }
                ?? controller.flatMap { $0.tabs.isEmpty ? nil : $0 }
            TerminalController.controller(owning: tab)?.detach(tab)

            // The option may have been turned off while the tab was gone. A
            // controller using native tabs keeps its sessions in a window tab
            // group, so putting one in its list would hide it from every way a
            // user has of reaching a tab.
            guard let destination else {
                let restored = TerminalController.newWindow(
                    ghostty,
                    adopting: tab,
                    position: frame.map { NSPoint(x: $0.minX, y: $0.maxY) },
                    inheritBackgroundOpacity: isBackgroundOpaque,
                    restoringFrame: frame)
                return restored
            }

            if destination.usesNonNativeTabs {
                destination.insert(tab, at: index)
                destination.showWindowSafely(nil)
                return destination
            }

            // Native tabs now. "Beside its neighbor" means a window of its own
            // in the neighbor's tab group, which is where a tab lives there.
            let restored = TerminalController.newWindow(
                ghostty,
                adopting: tab,
                inheritBackgroundOpacity: destination.isBackgroundOpaque)
            if let parent = destination.window, let window = restored.window {
                parent.addTabbedWindowSafely(
                    window, ordered: precedesNeighbor ? .below : .above)
            }

            return restored
        }
    }

    /// Register a move against its tab so closing either window preserves it.
    private func registerUndoForTabMove(_ tab: TerminalTab, to location: TabUndoLocation, action: String) {
        guard let undoManager else { return }
        let undoExpiration = self.undoExpiration
        let ghostty = self.ghostty
        undoManager.setActionName(action)
        undoManager.registerUndo(withTarget: tab, expiresAfter: undoExpiration) { [tab] _ in
            guard let owner = Self.controller(owning: tab),
                  let index = owner.tabs.firstIndex(where: { $0 === tab }) else { return }
            let inverse = TabUndoLocation(controller: owner, tab: tab, index: index)
            let restored = location.restore(tab, ghostty: ghostty)
            restored.registerUndoForTabMove(tab, to: inverse, action: action)
        }
    }

    /// Remove a tab without tearing down its surfaces, for a move elsewhere.
    ///
    /// Emptying the tree is what closes the window, via `surfaceTreeDidChange`,
    /// which is the same way a window goes away when its last split is dragged
    /// out.
    func detach(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

        // With tabs left behind this is exactly a removal, so let `removeTab`
        // do it. Only the last tab needs anything different here, because a
        // close would take the window with it and a move must not.
        guard !removeTab(at: index) else { return }

        tabs.remove(at: index)
        if Self.tabControllers.object(forKey: tab) === self {
            Self.tabControllers.removeObject(forKey: tab)
        }
        activeTabIndex = 0
        focusedSurface = nil
        ownedTreeDidChange(from: tab.surfaceTree, to: .init())

        // Emptying the tree closes this window, via `surfaceTreeDidChange`.
        // Deferred because a detach can happen inside a drag session owned by a
        // view in that window, which must not be torn down mid-event.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tabs.isEmpty else { return }
            self.surfaceTree = .init()
        }

        invalidateRestorableState()
    }

    /// Adopt a tab detached from somewhere else.
    func insert(_ tab: TerminalTab, at index: Int) {
        let insertAt = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: insertAt)

        Self.tabControllers.setObject(self, forKey: tab)
        ownedTreeDidChange(from: .init(), to: tab.surfaceTree)

        syncWindowRestorability()
        invalidateRestorableState()

        // An adopted tab is the one the user is moving, so it becomes active.
        // Force a reselect: `activeTabIndex` may already equal `insertAt`.
        activeTabIndex = -1
        selectTab(at: insertAt)
    }

    /// Release our ownership without changing the tabs saved by undo.
    private func releaseTabs() {
        let previousTabs = tabs
        tabs = []
        for tab in previousTabs {
            if Self.tabControllers.object(forKey: tab) === self {
                Self.tabControllers.removeObject(forKey: tab)
            }
            ownedTreeDidChange(from: tab.surfaceTree, to: .init())
        }
        focusedSurface = nil
    }

    /// Set a tab's color, keeping the titlebar indicator in step when it is the
    /// tab that indicator is showing.
    func setTabColor(_ color: TerminalTabColor, for tab: TerminalTab) {
        guard tab.tabColor != color else { return }
        tab.tabColor = color
        if tab === activeTab {
            (window as? TerminalWindow)?.tabColorDidChange()
        }
        invalidateRestorableState()
    }

    /// Called after the active tab changes.
    func activeTabDidChange() {
        // The window's name and color come from the tab that's on screen. The
        // computed half of the name arrives on its own: selecting a tab moves
        // focus, and the title follows whichever surface has it.
        if let tab = activeTab {
            // Writing this back into the tab it came from is a no-op.
            titleOverride = tab.titleOverride
        }

        // The titlebar color indicator follows whichever tab owns the color now.
        (window as? TerminalWindow)?.tabColorDidChange()

        // Which tab is selected is part of the restored state.
        invalidateRestorableState()
    }

    /// A tab dragged out of every window becomes a window of its own, which is
    /// what dragging a native tab out of the bar does.
    @objc func ghosttyTabDragEndedNoTarget(_ notification: Notification) {
        guard let tab = notification.object as? TerminalTab else { return }
        guard Self.controller(owning: tab) === self, tabs.count > 1 else { return }

        moveTabToNewWindow(
            tab,
            position: notification.userInfo?[Notification.Name.ghosttyTabDragEndedNoTargetPointKey] as? NSPoint)
    }

    // MARK: Tabs: Split Tree Management

    /// The bookkeeping `surfaceTree`'s `didSet` does, for a tab that isn't the
    /// active one and so never passes through it.
    func backgroundTabTreeDidChange(
        _ tab: TerminalTab,
        from oldTree: SplitTree<Ghostty.SurfaceView>,
        to newTree: SplitTree<Ghostty.SurfaceView>
    ) {
        ownedTreeDidChange(from: oldTree, to: newTree)

        // A focused surface we no longer own keeps its view alive through the
        // title subscription, and its process with it.
        if let focused = tab.focusedSurface, !newTree.contains(focused) {
            tab.focusedSurface = nil
        }

        // We rebind on what the tab is observing, not on the remembered focus.
        // Closing the remembered surface falls back to the first one, and if
        // that closes too we have no focus left to tell us the subscription is
        // watching something gone.
        if let observed = tab.observedSurface, !newTree.contains(observed) {
            tab.observeTitle()
        }

        invalidateRestorableState()

        // An emptied background tab goes away, the same way an emptied active
        // tree closes our window. `replaceSurfaceTree(_:in:)` gets there first
        // for its own tabs, so this is the funnel's own invariant.
        if newTree.isEmpty, let index = tabs.firstIndex(where: { $0 === tab }) {
            removeTab(at: index)
        }
    }

    /// Close a surface node in a specific tab, requesting confirmation if
    /// necessary. The tab may be a background one, which is why this exists
    /// alongside the base class version.
    func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        in tab: TerminalTab?,
        withConfirmation: Bool = true
    ) {
        guard let tab = tab ?? activeTab, tab.surfaceTree.contains(node) else { return }

        // If this isn't the root then we're dealing with a split closure, which
        // the base class handles. Our `removeSurfaceNode` override is what puts
        // it in the right tab.
        if tab.surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // More than 1 tab means we're closing a tab, not the window.
        if usesNonNativeTabs {
            if tabs.count > 1 {
                if withConfirmation {
                    closeTab(tab)
                } else {
                    closeTabImmediately(tab)
                }
            } else if withConfirmation {
                closeWindow(nil)
            } else {
                closeWindowImmediately()
            }
            return
        }

        // More than 1 window means we have tabs and we're closing a tab
        if window?.tabGroup?.windows.count ?? 0 > 1 {
            if withConfirmation {
                closeTab(nil)
            } else {
                closeTabImmediately()
            }
            return
        }

        // 1 window, closing the window
        if withConfirmation {
            closeWindow(nil)
        } else {
            closeWindowImmediately()
        }
    }

    /// Remove a node from a tab's surface tree and move focus appropriately.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node, in tab: TerminalTab?) {
        guard let tab = tab ?? activeTab else { return }

        // Focus only moves if the tab is the one on screen. A background tab
        // remembers its own focus and asserts it when it is next selected.
        let nextFocus: Ghostty.SurfaceView? = if tab === activeTab && node.contains(
            where: { $0 == focusedSurface }
        ) {
            Self.findNextFocusTargetAfterClosing(node: node, in: tab.surfaceTree)
        } else {
            nil
        }

        replaceSurfaceTree(
            tab.surfaceTree.removing(node),
            in: tab,
            // When a non-focused surface is removed and this window stays as the key window,
            // we should refocus the `focusedSurface` to make sure the window's firstResponder remains as it is.
            //
            // This is a weird workaround, since `resignFirstResponder` wasn't called on `focusedSurface` after drag,
            // but the first responder became the window itself.
            moveFocusTo: tab === activeTab ? nextFocus ?? focusedSurface : nil,
            undoAction: "Close Terminal"
        )
    }

    /// Give a tab a new split tree, with undo.
    ///
    /// Undo targets the tab rather than this controller, because a tab outlives
    /// the window it was in: dragging the last tab out of a window closes that
    /// window, and `windowWillClose` drops every undo registered against it.
    func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        in tab: TerminalTab?,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // Undo has to put the tree back where it came from. Without this the
        // closure writes into whatever tab is active when it runs, freeing that
        // tab's surfaces and killing the processes in them.
        guard let tab = tab ?? activeTab else { return }

        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately(tab)
            return
        }

        // Setup our new split tree
        let oldTree = tab.surfaceTree
        Self.setSurfaceTree(newTree, for: tab)
        if let newView {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: newView, from: oldView)
            }
        }

        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }

        let undoExpiration = self.undoExpiration
        // Our expiring undo targets are weak. Capture the tab so we keep
        // its surfaces alive until this action expires.
        undoManager.registerUndo(
            withTarget: tab,
            expiresAfter: undoExpiration
        ) { [tab] _ in
            Self.setSurfaceTree(oldTree, for: tab)
            if let oldView {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: oldView, from: Self.controller(owning: tab)?.focusedSurface)
                }
            }

            undoManager.registerUndo(
                withTarget: tab,
                expiresAfter: undoExpiration
            ) { [tab] _ in
                guard let owner = Self.controller(owning: tab) else { return }
                owner.replaceSurfaceTree(
                    newTree,
                    in: tab,
                    moveFocusTo: newView,
                    moveFocusFrom: owner.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }

    // MARK: Tabs: Combine

    /// Marks which tab rang, so the bar can show it. The window-wide aggregate
    /// is the base class's own subscription over the same publisher.
    private func setupTabBellPublisher() {
        tabBellCancellable = surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bells in
                guard let self else { return }
                for tab in tabs {
                    let tabBell = tab.surfaces.contains { bells[$0.id] ?? false }
                    if tab.bell != tabBell { tab.bell = tabBell }
                }
            }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(moveGhosttyTabToNewWindow):
            return usesNonNativeTabs && tabs.count > 1

        case #selector(mergeAllGhosttyWindows):
            return usesNonNativeTabs && NSApp.windows.contains {
                guard let other = $0.windowController as? TerminalController else { return false }
                return other !== self && other.usesNonNativeTabs
            }

        case #selector(closeTabsOnTheRight(_:)):
            if usesNonNativeTabs {
                return tabs.indices.contains { $0 > activeTabIndex }
            }

            guard let window, let tabGroup = window.tabGroup else { return false }
            guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return false }
            return tabGroup.windows.indices.contains { $0 > currentIndex }

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            // Maximize takes priority, we take up the full screen we're on.
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            // Initial size as requested by the configuration (e.g. `window-width`)
            // takes next priority.
            return .contentIntrinsicSize
        } else {
            return nil
        }
    }
}
