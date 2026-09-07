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

    /// Whether this window draws its own tab bar instead of using macOS native
    /// window tabbing. When true this window is a single `NSWindow` no matter
    /// how many sessions it holds, which is the whole point: native tabs are
    /// separate windows to the Accessibility API and therefore to every tiling
    /// window manager.
    override var usesNonNativeTabs: Bool {
        derivedConfig.macosNonNativeTabs
    }

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

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// Keeps our own tab bar in step with the tab count.
    private var tabBarCancellables: Set<AnyCancellable> = []

    /// Our own tab bar, when `macos-non-native-tabs`.
    private var tabBarAccessory: TerminalTabBarAccessoryViewController?

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

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

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
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
        in tab: TerminalTab? = nil,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately(tab)
            return
        }

        super.replaceSurfaceTree(
            newTree,
            in: tab,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
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
            parentController.showWindowSafely(self)
            NSApp.activate(ignoringOtherApps: true)

            if let undoManager = parentController.undoManager {
                undoManager.setActionName("New Tab")
                undoManager.registerUndo(
                    withTarget: parentController,
                    expiresAfter: parentController.undoExpiration
                ) { target in
                    undoManager.disableUndoRegistration {
                        guard let index = target.tabs.firstIndex(where: { $0 === tab }) else { return }
                        target.removeTab(at: index)
                    }

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

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // More than 1 tab means we're closing a tab, not the window.
        if usesNonNativeTabs {
            if tabs.count > 1 {
                if withConfirmation {
                    closeTab(nil)
                } else {
                    closeTabImmediately()
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

    func closeTabImmediately(_ tab: TerminalTab? = nil, registerRedo: Bool = true) {
        guard let window = window else { return }

        if usesNonNativeTabs {
            guard let tab = tab ?? activeTab else { return }

            // The last tab means the window goes with it.
            guard tabs.count > 1,
                  let index = tabs.firstIndex(where: { $0 === tab }) else {
                closeWindowImmediately()
                return
            }

            removeTab(at: index)

            if let undoManager {
                undoManager.setActionName("Close Tab")
                // The closure is what keeps the tab, and every surface in it,
                // alive until the undo expires.
                undoManager.registerUndo(
                    withTarget: self,
                    expiresAfter: undoExpiration
                ) { target in
                    target.insert(tab, at: index)

                    if registerRedo {
                        undoManager.registerUndo(
                            withTarget: target,
                            expiresAfter: target.undoExpiration
                        ) { target in
                            target.closeTabImmediately(tab)
                        }
                    }
                }
            }

            return
        }

        guard let tabGroup = window.tabGroup,
                tabGroup.windows.count > 1 else {
            closeWindowImmediately()
            return
        }

        cancelPendingInitialPresentation()

        // Undo
        if let undoManager, let undoState {
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

    private func closeOtherTabsImmediately() {
        guard let window = window else { return }

        let closeOthers: () -> Void
        if usesNonNativeTabs {
            guard tabs.count > 1 else { return }
            closeOthers = { [self] in
                // From the back so each tab's undo restores it at the index it
                // actually had.
                for tab in tabs.reversed() where tab !== activeTab {
                    closeTabImmediately(tab, registerRedo: false)
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

    private func closeTabsOnTheRightImmediately() {
        guard let window = window else { return }

        let closeToTheRight: () -> Void
        if usesNonNativeTabs {
            let toClose = tabs.enumerated().filter { $0.offset > activeTabIndex }.map(\.element)
            guard !toClose.isEmpty else { return }
            closeToTheRight = { [self] in
                // From the back so each tab's undo restores it at the index it
                // actually had.
                for tab in toClose.reversed() {
                    closeTabImmediately(tab, registerRedo: false)
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

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
    func closeWindowImmediately() {
        guard let window = window else { return }

        cancelPendingInitialPresentation()

        registerUndoForCloseWindow()

        if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
            tabGroup.windows.forEach { window in
                // Clear out the surfacetree to ensure there is no undo state.
                // This prevents unnecessary undos registered since AppKit may
                // process them on later ticks so we can't just disable undo registration.
                if let controller = window.windowController as? TerminalController {
                    controller.cancelPendingInitialPresentation()
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
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        weak var tabGroup: NSWindowTabGroup?
        let tabColor: TerminalTabColor

        /// Every tab in the window when Ghostty owns the tabs. Without this,
        /// undoing "Close Window" would bring back only the active one.
        let tabs: [TabUndoState]

        /// Which of `tabs` was selected.
        let activeTabIndex: Int

        struct TabUndoState {
            let surfaceTree: SplitTree<Ghostty.SurfaceView>
            let focusedSurface: UUID?
            let titleOverride: String?
            let tabColor: TerminalTabColor
        }
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        self.init(ghostty, withSurfaceTree: undoState.surfaceTree)

        // Bring back the other tabs before anything else, so the window is
        // whole by the time we size it and restore focus. Same insertion rule
        // as `TerminalWindowRestoration.restoreTabs`.
        if usesNonNativeTabs, undoState.tabs.count > 1 {
            let activeIndex = min(
                max(undoState.activeTabIndex, 0),
                undoState.tabs.count - 1)

            if let active = activeTab {
                active.titleOverride = undoState.tabs[activeIndex].titleOverride
                active.tabColor = undoState.tabs[activeIndex].tabColor
            }

            for (index, tab) in undoState.tabs.enumerated() where index != activeIndex {
                guard !tab.surfaceTree.isEmpty else { continue }
                guard let created = addTab(surfaceTree: tab.surfaceTree, at: index) else { continue }
                created.titleOverride = tab.titleOverride
                created.tabColor = tab.tabColor
                if let focused = tab.focusedSurface {
                    created.focusedSurface = created.surfaces.first { $0.id == focused }
                    created.observeTitle()
                }
            }

            selectTab(at: activeIndex)
        }

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

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
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
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

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: window.tabGroup?.windows.firstIndex(of: window),
            tabGroup: window.tabGroup,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none,
            tabs: tabs.map { tab in
                .init(
                    surfaceTree: tab.surfaceTree,
                    focusedSurface: tab.focusedSurface?.id,
                    titleOverride: tab.titleOverride,
                    tabColor: tab.tabColor)
            },
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
        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

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

    /// Move a tab out into a window of its own.
    ///
    /// This is what AppKit's `moveTabToNewWindow:` does for native tabs. That
    /// selector is disabled without a tab group, so with non-native tabs the Window
    /// menu item and the tab context menu come here instead.
    func moveTabToNewWindow(_ tab: TerminalTab, position: NSPoint? = nil) {
        guard usesNonNativeTabs, tabs.count > 1,
              let index = tabs.firstIndex(where: { $0 === tab }) else { return }

        // The new window builds its own tab around the tree, so the state that
        // isn't in the tree has to be carried across by hand.
        let created = TerminalController.newWindow(
            ghostty,
            tree: tab.surfaceTree,
            position: position,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
        if let moved = created.activeTab {
            moved.titleOverride = tab.titleOverride
            moved.tabColor = tab.tabColor
            moved.focusedSurface = tab.focusedSurface
            moved.observeTitle()
        }

        removeTab(at: index)

        guard let undoManager else { return }
        undoManager.setActionName("Move Tab to New Window")
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            // Detaching the new window's only tab closes it, and the tab that
            // comes back is the one that was over there, so anything renamed or
            // recolored in the meantime survives.
            guard let moved = created.activeTab else { return }
            undoManager.disableUndoRegistration {
                created.detach(moved)
                target.insert(moved, at: index)
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.moveTabToNewWindow(moved, position: position)
            }
        }
    }

    /// Install or remove the tab bar per `window-show-tab-bar`.
    ///
    /// The accessory is added and removed rather than hidden: an
    /// `NSTitlebarAccessoryViewController` marked `isHidden` still occupies the
    /// titlebar. When the bar is down the window title is the only thing naming
    /// the session, so it comes back; when the bar is up the centered title
    /// would only repeat what the active tab already says.
    private func syncTabBarVisibility() {
        guard usesNonNativeTabs, let window else { return }

        let visible: Bool
        switch derivedConfig.windowShowTabBar {
        case .always: visible = true
        case .auto: visible = tabs.count > 1
        case .never: visible = false
        }

        if visible {
            if tabBarAccessory == nil {
                let accessory = TerminalTabBarAccessoryViewController(controller: self)
                window.addTitlebarAccessoryViewController(accessory)
                tabBarAccessory = accessory
                syncAppearance()
            }
            if derivedConfig.macosTitlebarStyle == .tabs {
                window.titleVisibility = .hidden
            }
        } else {
            if let accessory = tabBarAccessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            tabBarAccessory = nil
            if derivedConfig.macosTitlebarStyle == .tabs {
                window.titleVisibility = .visible
            }
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
        guard let window = window else { return }

        let tabCount = usesNonNativeTabs ? tabs.count : (window.tabGroup?.windows.count ?? 0)
        guard tabCount > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    /// Close a specific tab, confirming first if it has a running process.
    func closeTab(_ tab: TerminalTab) {
        guard usesNonNativeTabs, tabs.contains(where: { $0 === tab }) else { return }

        // Closing the only tab closes the window.
        guard tabs.count > 1 else {
            closeWindow(nil)
            return
        }

        guard tab.surfaces.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately(tab)
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) { [weak self] in
            self?.closeTabImmediately(tab)
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard let window = window else { return }

        if usesNonNativeTabs {
            guard tabs.count > 1 else { return }

            let others = tabs.enumerated().filter { $0.offset != activeTabIndex }
            guard others.contains(where: { $0.element.surfaces.contains { $0.needsConfirmQuit } }) else {
                closeOtherTabsImmediately()
                return
            }

            confirmClose(
                messageText: "Close Other Tabs?",
                informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
            ) {
                self.closeOtherTabsImmediately()
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
        guard let window = window else { return }

        if usesNonNativeTabs {
            let toClose = tabs.enumerated().filter { $0.offset > activeTabIndex }
            guard !toClose.isEmpty else { return }

            guard toClose.contains(where: { $0.element.surfaces.contains { $0.needsConfirmQuit } }) else {
                closeTabsOnTheRightImmediately()
                return
            }

            confirmClose(
                messageText: "Close Tabs on the Right?",
                informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
            ) {
                self.closeTabsOnTheRightImmediately()
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
            closeWindowImmediately()
            return
        }
        if confirmControllers.count == 1 {
            // We call confirmClose on the proper controller so the alert is
            // attached to the window that needs confirmation.
            confirmControllers[0].confirmClose(
                messageText: "Close Window?",
                informativeText: "All terminal sessions in this window will be terminated.",
            ) {
                self.closeWindowImmediately()
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
                await reviewWindows(confirmControllers, window: window)
            case .alertSecondButtonReturn:
                closeWindowImmediately()
            default:
                break
            }
        }
    }

    private func reviewWindows(_ controllers: [TerminalController], window: NSWindow) async {
        for controller in controllers {
            let response = await controller.confirmCloseAsync(
                messageText: "Close Window?",
                informativeText: "All terminal sessions in this window will be terminated.",
            )

            if [.OK, .alertFirstButtonReturn].contains(response) {
                // Close this tab
                controller.closeTabImmediately()
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
            gotoCustomTab(tabIndex)
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
    private func gotoCustomTab(_ tabIndex: Int32) {
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
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
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
        let macosNonNativeTabs: Bool
        let windowShowTabBar: Ghostty.Config.WindowShowTabBar
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.macosNonNativeTabs = false
            self.windowShowTabBar = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.macosNonNativeTabs = config.macosNonNativeTabs
            self.windowShowTabBar = config.windowShowTabBar
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
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

        case #selector(closeTabsOnTheRight):
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
