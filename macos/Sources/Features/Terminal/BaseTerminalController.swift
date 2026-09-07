import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A base class for windows that can contain Ghostty windows. This base class implements
/// the bare minimum functionality that every terminal window in Ghostty should implement.
///
/// Usage: Specify this as the base class of your window controller for the window that contains
/// a terminal. The window controller must also be the window delegate OR the window delegate
/// functions on this base class must be called by your own custom delegate. For the terminal
/// view the TerminalView SwiftUI view must be used and this class is the view model and
/// delegate.
///
/// Special considerations to implement:
///
///   - Fullscreen: you must manually listen for the right notification and implement the
///   callback that calls toggleFullscreen on this base class.
///
/// Notably, things this class does NOT implement (not exhaustive):
///
///   - Tabbing, because there are many ways to get tabbed behavior in macOS and we
///   don't want to be opinionated about it.
///   - Window restoration or save state
///   - Window visual styles (such as titlebar colors)
///
/// The primary idea of all the behaviors we don't implement here are that subclasses may not
/// want these behaviors.
class BaseTerminalController: NSWindowController,
                              NSWindowDelegate,
                              TerminalViewDelegate,
                              TerminalViewModel,
                              ClipboardConfirmationViewDelegate,
                              FullscreenDelegate {
    /// Weak surface-to-controller ownership independent of AppKit's transient
    /// view and window attachment state.
    private static let surfaceControllers =
        NSMapTable<Ghostty.SurfaceView, BaseTerminalController>.weakToWeakObjects()

    /// The same, for tabs. A tab moves between windows by drag, and both undo
    /// and the drop target need to find where it is now.
    private static let tabControllers =
        NSMapTable<TerminalTab, BaseTerminalController>.weakToWeakObjects()

    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App

    /// The currently focused surface. This is always a surface in the active tab.
    var focusedSurface: Ghostty.SurfaceView? {
        didSet {
            activeTab?.focusedSurface = focusedSurface
            activeTab?.observeTitle()
            syncFocusToSurfaceTree()
        }
    }

    /// The tree of splits within the ACTIVE tab of this terminal window.
    ///
    /// Almost everything in the app means "the active tab" when it says
    /// "surface tree", which is why this keeps its name and its position on the
    /// controller. `allSurfaces` is the accessor for every surface in the
    /// window regardless of tab.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet {
            // Write straight back into the active tab, so `activeTab.surfaceTree`
            // and this are the same tree for as long as there is an active tab.
            // Everything that walks all tabs -- `allSurfaces`, occlusion, quit
            // confirmation, restoration -- relies on that.
            activeTab?.surfaceTree = surfaceTree
            updateSurfaceControllers(from: oldValue, to: surfaceTree)
            surfaceTreeDidChange(from: oldValue, to: surfaceTree)
        }
    }

    /// The tabs owned by this controller.
    ///
    /// This is non-empty for the entire lifetime of the controller after init.
    /// With native tabs it always has exactly one element,
    /// because in that mode a tab is a whole separate window with its own
    /// controller.
    @Published private(set) var tabs: [TerminalTab] = []

    /// The index into `tabs` of the tab whose content is currently displayed.
    @Published private(set) var activeTabIndex: Int = 0

    /// The tab whose content is currently displayed.
    var activeTab: TerminalTab? {
        tabs[safe: activeTabIndex]
    }

    /// Every surface in this window, across every tab.
    ///
    /// Use this (not `surfaceTree`) for anything that is a property of the
    /// window rather than of the visible session: quit confirmation, occlusion,
    /// teardown.
    var allSurfaces: [Ghostty.SurfaceView] {
        tabs.flatMap(\.surfaces)
    }

    /// Whether this controller draws its own tab bar rather than using macOS
    /// native window tabbing. Overridden by subclasses that support it.
    var usesNonNativeTabs: Bool { false }

    /// The number of tabs alongside this one, however tabs are implemented.
    ///
    /// With native tabbing that is the size of the window's tab group; with
    /// non-native tabs it is our own tab list. Callers deciding whether a tab
    /// action is possible must use this rather than reading `tabGroup`, which
    /// is empty by design when we own the tabs.
    var tabCount: Int {
        if usesNonNativeTabs { return tabs.count }
        return window?.tabGroup?.windows.count ?? (window == nil ? 0 : 1)
    }

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false

    /// Set if the terminal view should show the update overlay.
    @Published var updateOverlayIsVisible: Bool = false

    /// True when any surface in this controller currently has an active bell.
    @Published private(set) var bell: Bool = false

    /// Whether the terminal surface should focus when the mouse is over it.
    var focusFollowsMouse: Bool {
        self.derivedConfig.focusFollowsMouse
    }

    /// Non-nil when an alert is active so we don't overlap multiple.
    private var alert: NSAlert?

    /// The clipboard confirmation window, if shown.
    private var clipboardConfirmation: ClipboardConfirmationController?

    /// Fullscreen state management.
    private(set) var fullscreenStyle: FullscreenStyle?

    /// Event monitor (see individual events for why)
    private var eventMonitor: Any?

    /// The previous frame information from the window
    private var savedFrame: SavedFrame?

    /// Cache previously applied appearance to avoid unnecessary updates
    private var appliedColorScheme: ghostty_color_scheme_e?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Track whether background is forced opaque (true) or using config transparency (false)
    var isBackgroundOpaque: Bool = false

    /// The cancellables related to our focused surface.
    private var focusedSurfaceCancellables: Set<AnyCancellable> = []

    /// Cancellable for aggregating bell state across all surfaces in this controller.
    private var bellStateCancellable: AnyCancellable?

    /// Cancellable for clipboard confirmation requests from surfaces in this controller.
    private var clipboardConfirmationCancellable: AnyCancellable?

    /// Signals that the set of surfaces in this window may have changed. Sent
    /// after the change is committed, unlike `@Published`. See `allSurfacesPublisher`.
    let surfacesDidChangeSubject = CurrentValueSubject<Void, Never>(())

    /// An override title for the tab/window set by the user via prompt_tab_title.
    /// When set, this takes precedence over the computed title from the terminal.
    var titleOverride: String? {
        didSet {
            activeTab?.titleOverride = titleOverride
            applyTitleToWindow()
        }
    }

    /// The last computed title from the focused surface (without the override).
    private var lastComputedTitle: String = "👻"

    /// The time that undo/redo operations that contain running ptys are valid for.
    var undoExpiration: Duration {
        ghostty.config.undoTimeout
    }

    /// The undo manager for this controller is the undo manager of the window,
    /// which we set via the delegate method.
    override var undoManager: ExpiringUndoManager? {
        // This should be set via the delegate method windowWillReturnUndoManager
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        // If the window one isn't set, we fallback to our global one.
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            return appDelegate.undoManager
        }

        return nil
    }

    struct SavedFrame {
        let window: NSRect
        let screen: NSRect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    init(_ ghostty: Ghostty.App,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) {
        self.ghostty = ghostty
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(window: nil)

        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        let initialTree = tree ?? .init(view: Ghostty.SurfaceView(ghostty_app, baseConfig: base))
        self.tabs = [TerminalTab(surfaceTree: initialTree)]
        self.activeTabIndex = 0
        self.surfaceTree = initialTree
        updateSurfaceControllers(from: .init(), to: surfaceTree)
        tabs.forEach { Self.tabControllers.setObject(self, forKey: $0) }

        // Setup our bell state for the window
        setupBellNotificationPublisher()
        setupClipboardConfirmationPublisher()

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(didChangeScreenParametersNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChangeBase(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyCommandPaletteDidToggle(_:)),
            name: .ghosttyCommandPaletteDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyMaximizeDidToggle(_:)),
            name: .ghosttyMaximizeDidToggle,
            object: nil)

        // Splits
        center.addObserver(
            self,
            selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidToggleSplitZoom(_:)),
            name: Ghostty.Notification.didToggleSplitZoom,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidResizeSplit(_:)),
            name: Ghostty.Notification.didResizeSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidPresentTerminal(_:)),
            name: Ghostty.Notification.ghosttyPresentTerminal,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyTabDragEndedNoTarget(_:)),
            name: .ghosttyTabDragEndedNoTarget,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttySurfaceDragEndedNoTarget(_:)),
            name: .ghosttySurfaceDragEndedNoTarget,
            object: nil)

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: Methods

    /// Finds the controller whose split tree owns the given surface.
    ///
    /// A surface's `window` can briefly be nil or point at its previous window
    /// while AppKit is attaching or moving a native tab. Callers performing
    /// lifecycle operations must use tree ownership rather than that transient
    /// view relationship.
    static func controller(owning surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        if let controller = surfaceControllers.object(forKey: surface),
           controller.owns(surface) {
            return controller
        }

        if let controller = surface.window?.windowController as? BaseTerminalController,
           controller.owns(surface) {
            return controller
        }

        return NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .first { $0.owns(surface) }
    }

    /// Whether this controller owns the given surface in any of its tabs.
    func owns(_ surface: Ghostty.SurfaceView) -> Bool {
        tabs.contains { $0.surfaceTree.contains(surface) }
    }

    /// Finds the controller currently holding the given tab.
    static func controller(owning tab: TerminalTab) -> BaseTerminalController? {
        if let controller = tabControllers.object(forKey: tab),
           controller.tabs.contains(where: { $0 === tab }) {
            return controller
        }

        return NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .first { $0.tabs.contains { $0 === tab } }
    }

    private func updateSurfaceControllers(
        from oldTree: SplitTree<Ghostty.SurfaceView>,
        to newTree: SplitTree<Ghostty.SurfaceView>
    ) {
        // A surface leaving the active tab's tree hasn't necessarily left this
        // window, so only deregister surfaces no longer in ANY of our tabs.
        for surface in oldTree where !newTree.contains(surface) {
            if Self.surfaceControllers.object(forKey: surface) === self, !owns(surface) {
                Self.surfaceControllers.removeObject(forKey: surface)
            }
        }

        for surface in newTree {
            Self.surfaceControllers.setObject(self, forKey: surface)
        }
    }

    /// Create a new split.
    @discardableResult
    func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        // We can only create new splits for surfaces in our tree.
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

        // Create a new surface view
        guard let ghostty_app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)

        // Do the split
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: oldView,
                direction: direction)
        } catch {
            // If splitting fails for any reason (it should not), then we just log
            // and return. The new view we created will be deinitialized and its
            // no big deal.
            Ghostty.logger.warning("failed to insert split: \(error, privacy: .public)")
            return nil
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: "New Split")

        return newView
    }

    /// Move focus to a surface view.
    func focusSurface(_ view: Ghostty.SurfaceView) {
        // Check if target surface is in our tree
        guard surfaceTree.contains(view) else { return }

        // Move focus to the target surface and activate the window/app
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
            view.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Called when the surfaceTree variable changed.
    ///
    /// Subclasses should call super first.
    func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        for surfaceView in from where !to.contains(surfaceView) {
            cancelPendingClipboardConfirmation(for: surfaceView)
        }

        // If our surface tree becomes empty then we have no focused surface.
        if to.isEmpty {
            focusedSurface = nil
        }
        syncSurfaceTreeOcclusionState()
        surfacesDidChangeSubject.send()
    }

    /// Update all surfaces with the focus state. This ensures that libghostty has an accurate view about
    /// what surface is focused. This must be called whenever a surface OR window changes focus.
    func syncFocusToSurfaceTree() {
        var newlyFocused: Ghostty.SurfaceView?
        for surfaceView in allSurfaces {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this view.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                surfaceView == focusedSurface &&
                surfaceView.isFirstResponder
            surfaceView.focusDidChange(focused)
            if focused { newlyFocused = surfaceView }
        }

        if let newlyFocused {
            presentPendingClipboardConfirmation(for: newlyFocused)
        }
    }

    // Call this whenever the frame changes
    private func windowFrameDidChange() {
        // We need to update our saved frame information in case of monitor
        // changes (see didChangeScreenParameters notification).
        savedFrame = nil
        guard let window, let screen = window.screen else { return }
        savedFrame = .init(window: window.frame, screen: screen.visibleFrame)
    }

    func confirmCloseAsync(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close",
    ) async -> NSApplication.ModalResponse? {
        // If we already have an alert, we need to wait for that one.
        guard alert == nil else { return nil }

        // If there is no window to attach the modal then we assume success
        // since we'll never be able to show the modal.
        guard let window else {
            return .OK
        }

        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Store our alert so we only ever show one.
        self.alert = alert
        defer {
            // This is important so that we avoid losing focus when Stage
            // Manager is used (#8336)
            alert.window.orderOut(nil)
            self.alert = nil
        }
        return await alert.beginSheetModal(for: window)
    }

    func confirmClose(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close",
        completion: @escaping () -> Void
    ) {
        Task {
            guard let response = await confirmCloseAsync(messageText: messageText, informativeText: informativeText, confirmButtonTitle: confirmButtonTitle) else {
                completion()
                return
            }
            if [.alertFirstButtonReturn, .OK].contains(response) {
                completion()
            }
        }
    }

    /// Prompt the user to change the tab/window title.
    func promptTabTitle() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = titleOverride ?? window.title
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let newTitle = textField.stringValue
            if newTitle.isEmpty {
                self.titleOverride = nil
            } else {
                self.titleOverride = newTitle
            }
        }
    }

    /// Close a surface from a view.
    func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let node = surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, withConfirmation: withConfirmation)
    }

    /// Close a surface node (which may contain splits), requesting confirmation if necessary.
    ///
    /// This will also insert the proper undo stack information in.
    func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // This node must be part of our tree
        guard surfaceTree.contains(node) else { return }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            removeSurfaceNode(node)
            return
        }

        // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
        // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
        // confirmationDialog allows the user to Cmd-W close the alert, but when doing
        // so SwiftUI does not update any of the bindings to note that window is no longer
        // being shown, and provides no callback to detect this.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            if let self {
                self.removeSurfaceNode(node)
            }
        }
    }

    // MARK: Split Tree Management

    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    private func findNextFocusTargetAfterClosing(node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        guard let root = surfaceTree.root else { return nil }

        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }

    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    private func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        // Move focus if the closed surface was focused and we have a next target
        let nextFocus: Ghostty.SurfaceView? = if node.contains(
            where: { $0 == focusedSurface }
        ) {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        replaceSurfaceTree(
            surfaceTree.removing(node),
            // When a non-focused surface is removed and this window stays as the key window,
            // we should refocus the `focusedSurface` to make sure the window's firstResponder remains as it is.
            //
            // This is a weird workaround, since `resignFirstResponder` wasn't called on `focusedSurface` after drag,
            // but the first responder became the window itself.
            moveFocusTo: nextFocus ?? focusedSurface,
            undoAction: "Close Terminal"
        )
    }

    /// Give a tab a new split tree, going through `surfaceTree` while it is the
    /// active tab so the controller and what is on screen stay in step.
    ///
    /// The tab may have moved to another window since a caller captured it, so
    /// this always writes through whichever controller holds it now.
    static func setSurfaceTree(_ tree: SplitTree<Ghostty.SurfaceView>, for tab: TerminalTab) {
        guard let controller = controller(owning: tab) else {
            tab.surfaceTree = tree
            return
        }

        if tab === controller.activeTab {
            controller.surfaceTree = tree
        } else {
            tab.surfaceTree = tree
        }
    }

    func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        in tab: TerminalTab? = nil,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // Undo has to put the tree back where it came from. Without this the
        // closure writes into whatever tab is active when it runs, freeing that
        // tab's surfaces and killing the processes in them.
        guard let tab = tab ?? activeTab else { return }

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

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { [weak tab] target in
            guard let tab else { return }
            Self.setSurfaceTree(oldTree, for: tab)
            if let oldView {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { [weak tab] target in
                guard let tab else { return }
                target.replaceSurfaceTree(
                    newTree,
                    in: tab,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }

    // MARK: Notifications

    @objc private func didChangeScreenParametersNotification(_ notification: Notification) {
        // If we have a window that is visible and it is outside the bounds of the
        // screen then we clamp it back to within the screen.
        guard let window else { return }
        guard window.isVisible else { return }

        // We ignore fullscreen windows because macOS automatically resizes
        // those back to the fullscreen bounds.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let screen = window.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame

        // Clamp width/height
        if newFrame.size.width > visibleFrame.size.width {
            newFrame.size.width = visibleFrame.size.width
        }
        if newFrame.size.height > visibleFrame.size.height {
            newFrame.size.height = visibleFrame.size.height
        }

        // Ensure the window is on-screen. We only do this if the previous frame
        // was also on screen. If a user explicitly wanted their window off screen
        // then we let it stay that way.
        x: if newFrame.origin.x < visibleFrame.origin.x {
            if let savedFrame, savedFrame.window.origin.x < savedFrame.screen.origin.x {
                break x
            }

            newFrame.origin.x = visibleFrame.origin.x
        }
        y: if newFrame.origin.y < visibleFrame.origin.y {
            if let savedFrame, savedFrame.window.origin.y < savedFrame.screen.origin.y {
                break y
            }

            newFrame.origin.y = visibleFrame.origin.y
        }

        // Apply the new window frame
        window.setFrame(newFrame, display: true)
    }

    @objc private func ghosttyConfigDidChangeBase(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)
    }

    @objc private func ghosttyCommandPaletteDidToggle(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        toggleCommandPalette(nil)
    }

    @objc private func ghosttyMaximizeDidToggle(_ notification: Notification) {
        guard let window else { return }
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        window.zoom(nil)
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let node = surfaceTree.root?.node(view: target) else { return }
        closeSurface(
            node,
            withConfirmation: (notification.userInfo?["process_alive"] as? Bool) ?? false)
    }

    @objc private func ghosttyDidNewSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let oldView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: oldView) != nil else { return }

        // Notification must contain our base config
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        // Determine our desired direction
        guard let directionAny = notification.userInfo?["direction"] else { return }
        guard let direction = directionAny as? ghostty_action_split_direction_e else { return }
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        newSplit(at: oldView, direction: splitDirection, baseConfig: config)
    }

    @objc private func ghosttyDidEqualizeSplits(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }

        // Check if target surface is in current controller's tree
        guard surfaceTree.contains(target) else { return }

        // Equalize the splits
        surfaceTree = surfaceTree.equalized()
    }

    @objc private func ghosttyDidFocusSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        // Get the direction from the notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.SplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitFocusDirection else { return }

        // Find the node for the target surface
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Find the next surface to focus
        guard let nextSurface = surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode) else {
            return
        }

        if surfaceTree.zoomed != nil {
            if derivedConfig.splitPreserveZoom.contains(.navigation) {
                surfaceTree = SplitTree(
                    root: surfaceTree.root,
                    zoomed: surfaceTree.root?.node(view: nextSurface))
            } else {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }
        }

        // Move focus to the next surface
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: nextSurface, from: target)
        }
    }

    @objc private func ghosttyDidToggleSplitZoom(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Toggle the zoomed state
        if surfaceTree.zoomed == targetNode {
            // Already zoomed, unzoom it
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            // We require that the split tree have splits
            guard surfaceTree.isSplit else { return }

            // Not zoomed or different node zoomed, zoom this node
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: targetNode)
        }

        // Move focus to our window. Importantly this ensures that if we click the
        // reset zoom button in a tab bar of an unfocused tab that we become focused.
        window?.makeKeyAndOrderFront(nil)

        // Ensure focus stays on the target surface. We lose focus when we do
        // this so we need to grab it again.
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
        }
    }

    @objc private func ghosttyDidResizeSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Extract direction and amount from notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitResizeDirection else { return }

        guard let amountAny = notification.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] else { return }
        guard let amount = amountAny as? UInt16 else { return }

        // Convert Ghostty.SplitResizeDirection to SplitTree.Spatial.Direction
        let spatialDirection: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }

        // Use viewBounds for the spatial calculation bounds
        let bounds = CGRect(origin: .zero, size: surfaceTree.viewBounds())

        // Perform the resize using the new SplitTree resize method
        do {
            surfaceTree = try surfaceTree.resizing(node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Ghostty.logger.warning("failed to resize split: \(error, privacy: .public)")
        }
    }

    @objc private func ghosttyDidPresentTerminal(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }

        // Bring the window to front and focus the surface.
        window?.makeKeyAndOrderFront(nil)

        // We use a small delay to ensure this runs after any UI cleanup
        // (e.g., command palette restoring focus to its original surface).
        Ghostty.moveFocus(to: target)
        Ghostty.moveFocus(to: target, delay: 0.1)

        // Show a brief highlight to help the user locate the presented terminal.
        target.highlight()
    }

    /// A tab dragged out of every window becomes a window of its own, which is
    /// what dragging a native tab out of the bar does.
    @objc private func ghosttyTabDragEndedNoTarget(_ notification: Notification) {
        guard let tab = notification.object as? TerminalTab else { return }
        guard Self.controller(owning: tab) === self, tabs.count > 1 else { return }

        (self as? TerminalController)?.moveTabToNewWindow(
            tab,
            position: notification.userInfo?[Notification.Name.ghosttyTabDragEndedNoTargetPointKey] as? NSPoint)
    }

    @objc private func ghosttySurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }

        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        _ = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: notification.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
    }

    // MARK: Local Events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .flagsChanged:
            localEventFlagsChanged(event)

        default:
            event
        }
    }

    private func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
        var surfaces: [Ghostty.SurfaceView] = surfaceTree.map { $0 }

        // If we're the main window receiving key input, then we want to avoid
        // calling this on our focused surface because that'll trigger a double
        // flagsChanged call.
        if NSApp.mainWindow == window {
            surfaces = surfaces.filter { $0 != focusedSurface }
        }

        for surface in surfaces {
            surface.flagsChanged(with: event)
        }

        return event
    }

    // MARK: TerminalViewDelegate

    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        focusedSurface = to

        // Important to cancel any prior subscriptions
        focusedSurfaceCancellables = []

        // Setup our title listener. If we have a focused surface we always use that.
        // Otherwise, we try to use our last focused surface. In either case, we only
        // want to care if the surface is in the tree so we don't listen to titles of
        // closed surfaces.
        if let titleSurface = focusedSurface ?? lastFocusedSurface,
           surfaceTree.contains(titleSurface) {
            // If we have a surface, we want to listen for title changes.
            titleSurface.$title
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            // There is no surface to listen to titles for.
            titleDidChange(to: "👻")
        }
    }

    private func computeTitle(title: String, bell: Bool) -> String {
        var result = title
        if bell && ghostty.config.bellFeatures.contains(.title) {
            result = "🔔 \(result)"
        }

        return result
    }

    private func titleDidChange(to: String) {
        lastComputedTitle = to
        applyTitleToWindow()
    }

    private func applyTitleToWindow() {
        guard let window else { return }

        if let titleOverride {
            window.title = computeTitle(
                title: titleOverride,
                bell: focusedSurface?.bell ?? false)
            return
        }

        window.title = lastComputedTitle
    }

    func pwdDidChange(to: URL?) {
        guard let window else { return }

        if derivedConfig.macosTitlebarProxyIcon == .visible {
            // Use the 'to' URL directly
            window.representedURL = to
        } else {
            window.representedURL = nil
        }
    }

    func cellSizeDidChange(to: NSSize) {
        guard derivedConfig.windowStepResize else { return }
        // Stage manager can sometimes present windows in such a way that the
        // cell size is temporarily zero due to the window being tiny. We can't
        // set content resize increments to this value, so avoid an assertion failure.
        guard to.width > 0 && to.height > 0 else { return }
        self.window?.contentResizeIncrements = to
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    private func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Ghostty.logger.warning("failed to replace node during split resize: \(error, privacy: .public)")
        }
    }

    private func splitDidDrop(
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }

        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Ghostty.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed to insert surface during drop: \(error, privacy: .public)")
                return
            }

            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Split")
            return
        }

        // Source is not in our tree - search other windows
        var sourceController: BaseTerminalController?
        var sourceNode: SplitTree<Ghostty.SurfaceView>.Node?
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            if let node = controller.surfaceTree.root?.node(view: source) {
                sourceController = controller
                sourceNode = node
                break
            }
        }

        guard let sourceController, let sourceNode else {
            Ghostty.logger.warning("source surface not found in any window during drop")
            return
        }

        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert surface during cross-window drop: \(error, privacy: .public)")
            return
        }

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)

        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surface else { return }
        let len = action.utf8CString.count
        if len == 0 { return }
        _ = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
        }
    }

    // MARK: Appearance

    /// Toggle the background opacity between transparent and opaque states.
    /// Do nothing if the configured background-opacity is >= 1 (already opaque).
    /// Subclasses should override this to add platform-specific checks and sync appearance.
    func toggleBackgroundOpacity() {
        // Do nothing if config is already fully opaque
        guard ghostty.config.backgroundOpacity < 1 else { return }

        // Do nothing if in fullscreen (transparency doesn't apply in fullscreen)
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        let newValue = !isBackgroundOpaque
        let controllers = NSApplication.shared.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        for controller in controllers {
            controller.isBackgroundOpaque = newValue
            controller.syncAppearance()
        }
    }

    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance. The list below should be updated
    /// as we add new things:
    ///
    ///  - ``toggleBackgroundOpacity``
    func syncAppearance() {
        // Purposely a no-op. This lets subclasses override this and we can call
        // it virtually from here.
    }

    // MARK: Fullscreen

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        var newStyle = mode.style(for: window)
        newStyle?.delegate = self
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = newStyle
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle!) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then set the new style for future use
                oldStyle.exit()
                self.fullscreenStyle = newStyle

                // We're done
                return
            }

            // Style is the same.
        } else {
            // We have no previous style
            self.fullscreenStyle = newStyle
        }
        guard let fullscreenStyle else { return }

        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }
    }

    func fullscreenDidChange() {
        guard let fullscreenStyle else { return }

        // When we enter fullscreen, we want to show the update overlay so that it
        // is easily visible. For native fullscreen this is visible by showing the
        // menubar but we don't want to rely on that.
        if fullscreenStyle.isFullscreen {
            updateOverlayIsVisible = true
        } else {
            updateOverlayIsVisible = defaultUpdateOverlayVisibility()
        }

        // Always resync our appearance
        syncAppearance()
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()

        // Setup our undo manager.

        // Everything beyond here is setting up the window
        guard let window else { return }

        // We always initialize our fullscreen style to native if we can because
        // initialization sets up some state (i.e. observers). If its set already
        // somehow we don't do this.
        if fullscreenStyle == nil {
            fullscreenStyle = NativeFullscreen(window)
            fullscreenStyle?.delegate = self
        }

        // Set our update overlay state
        updateOverlayIsVisible = defaultUpdateOverlayVisibility()
    }

    func defaultUpdateOverlayVisibility() -> Bool {
        guard let window else { return true }

        // No titlebar we always show the update overlay because it can't support
        // updates in the titlebar
        guard window.styleMask.contains(.titled) else {
            return true
        }

        // If it's a non terminal window we can't trust it has an update accessory,
        // so we always want to show the overlay.
        guard let window = window as? TerminalWindow else {
            return true
        }

        // Show the overlay if the window isn't.
        return !window.supportsUpdateAccessory
    }

    // MARK: NSWindowDelegate

    /// Check whether window should be closed without showing an alert
    func windowCanBeClosedWithoutConfirmation() -> Bool {
        // We must have a window. Is it even possible not to?
        guard window != nil else { return true }

        // If we have no surfaces, close.
        let surfaces = allSurfaces
        if surfaces.isEmpty { return true }

        // If we already have an alert, continue with it
        guard alert == nil else { return false }

        // If our surfaces don't require confirmation, close.
        if !surfaces.contains(where: { $0.needsConfirmQuit }) { return true }

        return false
    }

    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !windowCanBeClosedWithoutConfirmation() else {
            return true
        }
        // We require confirmation, so show an alert as long as we aren't already.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            self?.window?.close()
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        for surfaceView in allSurfaces {
            cancelPendingClipboardConfirmation(for: surfaceView)
        }

        // Emit a final bell-state transition so any observers can clear state
        // without separately tracking NSWindow lifecycle events.
        if bell {
            bell = false
            NotificationCenter.default.post(
                name: .terminalWindowBellDidChangeNotification,
                object: self,
                userInfo: [Notification.Name.terminalWindowHasBellKey: false]
            )
        }

        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        window.contentView = nil

        // Make sure we clean up all our undos
        window.undoManager?.removeAllActions(withTarget: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // If when we become key our first responder is the window itself, then we
        // want to move focus to our focused terminal surface. This works around
        // various weirdness with moving surfaces around.
        if let window, window.firstResponder == window, let focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }

        // Becoming key can race with responder updates when activating a window.
        // Sync on the next runloop so split focus has settled first.
        DispatchQueue.main.async {
            self.syncFocusToSurfaceTree()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncSurfaceTreeOcclusionState()
    }

    private func syncSurfaceTreeOcclusionState() {
        let windowVisible = self.window?.occlusionState.contains(.visible) ?? false
        for (index, tab) in tabs.enumerated() {
            // Surfaces in a background tab are not on screen at all, no matter
            // what the window's occlusion state says.
            let visible = windowVisible && index == activeTabIndex
            for view in tab.surfaceTree {
                if let surface = view.surface, view.isWindowVisible != visible {
                    ghostty_surface_set_occlusion(surface, visible)
                    view.isWindowVisible = visible
                }
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    // MARK: First Responder

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        window.performClose(sender)
    }

    @IBAction func changeTabTitle(_ sender: Any) {
        if let targetWindow = window {
            let inlineHostWindow =
                targetWindow.tabbedWindows?
                    .first(where: { $0.tabBarView != nil }) as? TerminalWindow
                ?? (targetWindow as? TerminalWindow)

            if let inlineHostWindow, inlineHostWindow.beginInlineTabTitleEdit(for: targetWindow) {
                return
            }
        }

        promptTabTitle()
    }

    @IBAction func splitRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @IBAction func splitLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_LEFT)
    }

    @IBAction func splitDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @IBAction func splitUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_UP)
    }

    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }

    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }

    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }

    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .up)
    }

    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .down)
    }

    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }

    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }

    @IBAction func equalizeSplits(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitEqualize(surface: surface)
    }

    @IBAction func moveSplitDividerUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .up, amount: 10)
    }

    @IBAction func moveSplitDividerDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .down, amount: 10)
    }

    @IBAction func moveSplitDividerLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .left, amount: 10)
    }

    @IBAction func moveSplitDividerRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .right, amount: 10)
    }

    private func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }

    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .reset)
    }

    @IBAction func toggleCommandPalette(_ sender: Any?) {
        commandPaletteIsShowing.toggle()
        if commandPaletteIsShowing {
            // Fix the incorrect focus when toggling from InlineTitleEditor
            // When toggling the command palette from the inline title editor,
            // the first responder state of the surface is changed quickly from true to false.

            // `makeFirstResponder:` is called by the title editor when finishing,
            // but it happens **after** the command palette is shown,
            // so the `focused` is set to `true` while the command palette is shown.
            // (Could be an AppKit issue as well, since the resign is not called after but the command palette is receiving `keyDown`).

            // Since `performKeyEquivalent(with:)` is called on all of the subviews
            // until one of the return `true` so the paste action is consumed by the surface
            // instead of the first responder (command palette).
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    @IBAction func find(_ sender: Any) {
        focusedSurface?.find(sender)
    }

    @IBAction func selectionForFind(_ sender: Any) {
        focusedSurface?.selectionForFind(sender)
    }

    @IBAction func scrollToSelection(_ sender: Any) {
        focusedSurface?.scrollToSelection(sender)
    }

    @IBAction func findNext(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }

    @IBAction func findPrevious(_ sender: Any) {
        focusedSurface?.findPrevious(sender)
    }

    @IBAction func findHide(_ sender: Any) {
        focusedSurface?.findHide(sender)
    }

    @objc func resetTerminal(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.resetTerminal(surface: surface)
    }

    private struct DerivedConfig {
        let macosTitlebarProxyIcon: Ghostty.MacOSTitlebarProxyIcon
        let windowStepResize: Bool
        let focusFollowsMouse: Bool
        let splitPreserveZoom: Ghostty.Config.SplitPreserveZoom

        init() {
            self.macosTitlebarProxyIcon = .visible
            self.windowStepResize = false
            self.focusFollowsMouse = false
            self.splitPreserveZoom = .init()
        }

        init(_ config: Ghostty.Config) {
            self.macosTitlebarProxyIcon = config.macosTitlebarProxyIcon
            self.windowStepResize = config.windowStepResize
            self.focusFollowsMouse = config.focusFollowsMouse
            self.splitPreserveZoom = config.splitPreserveZoom
        }
    }
}

extension BaseTerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findHide):
            return focusedSurface?.searchState != nil

        default:
            return true
        }
    }

    // MARK: - Surface Color Scheme

    /// Update the surface tree's color scheme only when it actually changes.
    ///
    /// Calling ``ghostty_surface_set_color_scheme`` triggers
    /// ``syncAppearance(_:)`` via notification,
    /// so we avoid redundant calls.
    func updateColorSchemeForSurfaceTree() {
        /// Derive the target scheme from `window-theme` or system appearance.
        /// We set the scheme on surfaces so they pick the correct theme
        /// and let ``syncAppearance(_:)`` update the window accordingly.
        ///
        /// Using App's effectiveAppearance here to prevent incorrect updates.
        let themeAppearance = NSApplication.shared.effectiveAppearance
        let scheme: ghostty_color_scheme_e
        if themeAppearance.isDark {
            scheme = GHOSTTY_COLOR_SCHEME_DARK
        } else {
            scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        }
        guard scheme != appliedColorScheme else {
            return
        }
        for surfaceView in surfaceTree {
            if let surface = surfaceView.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }
        appliedColorScheme = scheme
    }
}

// MARK: Tabs

extension BaseTerminalController {
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
            at: index)
    }

    /// Add an existing split tree as a new tab, and select it.
    @discardableResult
    func addTab(
        surfaceTree tree: SplitTree<Ghostty.SurfaceView>,
        at index: Int? = nil
    ) -> TerminalTab? {
        guard !tree.isEmpty else { return nil }

        let tab = TerminalTab(surfaceTree: tree)
        let insertAt = min(max(index ?? tabs.count, 0), tabs.count)
        tabs.insert(tab, at: insertAt)

        // Keep the active index pointing at the same tab it did before.
        if insertAt <= activeTabIndex { activeTabIndex += 1 }

        // Register ownership immediately: notifications from these surfaces can
        // arrive before the tab is ever selected.
        Self.tabControllers.setObject(self, forKey: tab)
        for surface in tree {
            Self.surfaceControllers.setObject(self, forKey: surface)
        }

        surfacesDidChangeSubject.send()
        selectTab(at: insertAt)
        return tab
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

        let target = incoming.focusedSurface ?? incoming.surfaces.first
        focusedSurface = target
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

        // Deregister before dropping so a surface that somehow outlives the tab
        // doesn't keep resolving to this controller.
        if Self.tabControllers.object(forKey: removed) === self {
            Self.tabControllers.removeObject(forKey: removed)
        }
        for surface in removed.surfaces {
            cancelPendingClipboardConfirmation(for: surface)
            if Self.surfaceControllers.object(forKey: surface) === self {
                Self.surfaceControllers.removeObject(forKey: surface)
            }
        }

        tabs.remove(at: index)

        if wasActive {
            // Fall to the tab that took this one's place, else the new last.
            let target = min(index, tabs.count - 1)
            // Force a reselect: activeTabIndex may already equal `target`.
            activeTabIndex = -1
            selectTab(at: target)
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }

        surfacesDidChangeSubject.send()
        return true
    }

    /// Move the active tab by the given signed amount, clamped to the ends.
    func moveActiveTab(amount: Int) {
        guard tabs.count > 1, amount != 0 else { return }
        let from = activeTabIndex
        moveTab(from: from, to: min(max(from + amount, 0), tabs.count - 1))
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

        source.detach(tab)
        insert(tab, at: index)
    }

    /// Remove a tab without tearing down its surfaces, for a move elsewhere.
    ///
    /// Emptying the tree is what closes the window, via `surfaceTreeDidChange`,
    /// which is the same way a window goes away when its last split is dragged
    /// out.
    func detach(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

        if Self.tabControllers.object(forKey: tab) === self {
            Self.tabControllers.removeObject(forKey: tab)
        }
        for surface in tab.surfaces {
            cancelPendingClipboardConfirmation(for: surface)
            if Self.surfaceControllers.object(forKey: surface) === self {
                Self.surfaceControllers.removeObject(forKey: surface)
            }
        }

        if tabs.count > 1 {
            tabs.remove(at: index)
            if index == activeTabIndex {
                let target = min(index, tabs.count - 1)
                activeTabIndex = -1
                selectTab(at: target)
            } else if index < activeTabIndex {
                activeTabIndex -= 1
            }
        } else {
            tabs = []
            activeTabIndex = 0
            focusedSurface = nil

            // Emptying the tree closes this window, via `surfaceTreeDidChange`.
            // Deferred because a detach can happen inside a drag session owned
            // by a view in that window, which must not be torn down mid-event.
            DispatchQueue.main.async { [weak self] in
                self?.surfaceTree = .init()
            }
        }

        surfacesDidChangeSubject.send()
    }

    /// Adopt a tab detached from somewhere else.
    func insert(_ tab: TerminalTab, at index: Int) {
        let insertAt = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: insertAt)

        Self.tabControllers.setObject(self, forKey: tab)
        for surface in tab.surfaces {
            Self.surfaceControllers.setObject(self, forKey: surface)
        }

        surfacesDidChangeSubject.send()

        // An adopted tab is the one the user is moving, so it becomes active.
        // Force a reselect: `activeTabIndex` may already equal `insertAt`.
        activeTabIndex = -1
        selectTab(at: insertAt)
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

    /// Called after the active tab changes. Subclasses should call super.
    func activeTabDidChange() {
        // Adopt the incoming tab's title and override so the window chrome
        // matches the session that's now on screen.
        if let tab = activeTab {
            lastComputedTitle = tab.computedTitle
            // Writing this back into the tab it came from is a no-op.
            titleOverride = tab.titleOverride
        }
        applyTitleToWindow()

        // The titlebar color indicator follows whichever tab owns the color now.
        (window as? TerminalWindow)?.tabColorDidChange()

        // Which tab is selected is part of the restored state.
        invalidateRestorableState()
    }
}

// MARK: Clipboard Confirmation

extension BaseTerminalController {
    /// Presents clipboard confirmations published by surfaces in this controller.
    private func setupClipboardConfirmationPublisher() {
        clipboardConfirmationCancellable = allSurfacesPublisher
            // Rebuild the merged publisher whenever the surfaces change.
            .map { surfaces in
                Publishers.MergeMany(surfaces.map { surface in
                    // Carry the stable value-type ID rather than capturing the
                    // surface in the operator chain. The subscription therefore
                    // cannot extend the SurfaceView's lifetime.
                    let id = surface.id
                    return surface.$pendingClipboardConfirmation
                        .map { (id, $0) }
                        .eraseToAnyPublisher()
                })
                .eraseToAnyPublisher()
            }
            // Cancelling the old MergeMany releases every subscription for
            // surfaces removed from the current tree.
            .switchToLatest()
            // Published emits synchronously from the libghostty callback. Hop
            // to the main queue both for AppKit and so completing a request
            // cannot invalidate callback state while that callback is active.
            .receive(on: DispatchQueue.main)
            // The cancellable is controller-owned, so capture it weakly here to
            // avoid controller -> cancellable -> sink -> controller.
            .sink { [weak self] id, request in
                guard let self,
                      let surface = allSurfaces.first(where: { $0.id == id }) else { return }
                onConfirmClipboardRequest(request, for: surface)
            }
    }

    private func onConfirmClipboardRequest(
        _ request: Ghostty.ClipboardConfirmationRequest?,
        for target: Ghostty.SurfaceView
    ) {
        guard let request else {
            guard target.pendingClipboardConfirmation == nil,
                  let confirmation = clipboardConfirmation,
                  confirmation.confirmation.surface === target else { return }
            dismissClipboardConfirmation(confirmation)
            return
        }

        // Ignore values queued before a newer request replaced them.
        guard target.pendingClipboardConfirmation === request else { return }

        // SurfaceView.didSet has already cancelled the request that this one
        // replaced. If that request owns the visible sheet, update the sheet
        // in place. Dismissing it would briefly return focus to the terminal,
        // which can produce another request and repeat the cycle. Requests
        // from other surfaces cannot replace a window-modal sheet.
        if let confirmation = clipboardConfirmation {
            if confirmation.confirmation === request { return }
            guard confirmation.confirmation.surface === target else {
                target.pendingClipboardConfirmation = nil
                return
            }
            confirmation.replaceConfirmation(with: request)
            return
        }

        // A clipboard confirmation can originate from a surface that isn't
        // focused. Presenting its sheet immediately would bring that surface's
        // window or tab forward and steal focus. Signal that it needs attention,
        // retain the request on the surface, and present it only after the
        // surface gains focus.
        if !target.focused {
            if !target.bell {
                NotificationCenter.default.post(
                    name: .ghosttyBellDidRing,
                    object: target)
            }
            return
        }

        // Preserve the prior behavior for confirmation types other than an
        // OSC 52 read: only the controller's selected surface may present it.
        guard target == focusedSurface else {
            target.pendingClipboardConfirmation = nil
            return
        }
        _ = presentClipboardConfirmation(request)
    }

    private func presentClipboardConfirmation(
        _ request: Ghostty.ClipboardConfirmationRequest
    ) -> Bool {
        guard clipboardConfirmation == nil, let window else { return false }

        clipboardConfirmation = ClipboardConfirmationController(
            confirmation: request,
            delegate: self
        )
        window.beginSheet(clipboardConfirmation!.window!)
        return true
    }

    private func dismissClipboardConfirmation(
        _ confirmation: ClipboardConfirmationController
    ) {
        guard clipboardConfirmation === confirmation else { return }
        clipboardConfirmation = nil
        if let confirmationWindow = confirmation.window {
            window?.endSheet(confirmationWindow)
        }
    }

    private func presentPendingClipboardConfirmation(for target: Ghostty.SurfaceView) {
        guard target.focused,
              target == focusedSurface,
              let request = target.pendingClipboardConfirmation else { return }
        onConfirmClipboardRequest(request, for: target)
    }

    private func cancelPendingClipboardConfirmation(for target: Ghostty.SurfaceView) {
        if let confirmation = clipboardConfirmation,
           confirmation.confirmation.surface === target {
            dismissClipboardConfirmation(confirmation)
        }
        target.pendingClipboardConfirmation = nil
    }

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, remember: Bool) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        dismissClipboardConfirmation(cc)

        switch action {
        case .cancel:
            cc.confirmation.cancel()
        case .confirm:
            cc.confirmation.complete(remember: remember)
        }

        // Clear only if this is still the surface's current request. Completing
        // the request may synchronously cause a newer request to replace it.
        if let target = cc.confirmation.surface,
           target.pendingClipboardConfirmation === cc.confirmation {
            target.pendingClipboardConfirmation = nil
        }
    }
}

// MARK: Combine Methods

extension BaseTerminalController {
    /// Publishes an app-wide notification whenever this terminal window's aggregate
    /// bell state changes.
    private func setupBellNotificationPublisher() {
        bellStateCancellable = surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bells in
                guard let self else { return }

                // Per-tab state first, so the tab bar can mark which tab rang
                // rather than only whether the window did.
                for tab in tabs {
                    let tabBell = tab.surfaces.contains { bells[$0.id] ?? false }
                    if tab.bell != tabBell { tab.bell = tabBell }
                }

                let hasBell = bells.values.contains(true)
                guard bell != hasBell else { return }
                bell = hasBell
                NotificationCenter.default.post(
                    name: .terminalWindowBellDidChangeNotification,
                    object: self,
                    userInfo: [Notification.Name.terminalWindowHasBellKey: hasBell]
                )
            }
    }

    /// Creates a publisher for values on all surfaces in this controller's tree.
    ///
    /// The publisher emits a dictionary of surface IDs to values whenever the tree changes
    /// or any surface publishes a new value for the key path.
    func surfaceValuesPublisher<Value>(
        valueKeyPath: KeyPath<Ghostty.SurfaceView, Value>,
        publisherKeyPath: KeyPath<Ghostty.SurfaceView, Published<Value>.Publisher>
    ) -> AnyPublisher<[Ghostty.SurfaceView.ID: Value], Never> {
        // The surface set can be replaced entirely when splits or tabs are
        // added/removed/closed. For each snapshot we build a fresh publisher
        // that watches all surfaces in that snapshot.
        allSurfacesPublisher
            .map { surfaces in
                surfaces.valuesPublisher(
                    valueKeyPath: valueKeyPath,
                    publisherKeyPath: publisherKeyPath
                )
            }
            // Keep only the latest snapshot's publisher active. This automatically
            // cancels subscriptions for surfaces that are gone.
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    /// Emits every surface in this window, across every tab, whenever that set
    /// can have changed.
    ///
    /// This is driven by an explicit subject rather than `$surfaceTree` because
    /// `@Published` emits from `willSet`, so a subscriber reading back through
    /// the controller would see the tree that is being replaced. `surfacesDidChange`
    /// is sent from `didSet` instead, once the new state is committed.
    var allSurfacesPublisher: AnyPublisher<[Ghostty.SurfaceView], Never> {
        surfacesDidChangeSubject
            .compactMap { [weak self] in self?.allSurfaces }
            .eraseToAnyPublisher()
    }
}

// MARK: Notifications

extension Notification.Name {
    /// Terminal window aggregate bell state changed.
    static let terminalWindowBellDidChangeNotification = Notification.Name("com.mitchellh.ghostty.terminalWindowBellDidChange")
    static let terminalWindowHasBellKey = terminalWindowBellDidChangeNotification.rawValue + ".hasBell"
}
