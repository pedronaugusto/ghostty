import AppKit
import Combine
import SwiftUI

/// Hosts Ghostty's own tab bar in the window's titlebar.
///
/// This uses the same titlebar accessory slots AppKit itself uses for the real
/// `NSTabBar`. Nothing here has to fight AppKit for an existing view the way
/// `TitlebarTabsTahoeTerminalWindow` does, because here we own the view
/// outright.
///
/// The controller is referenced only weakly, through the view model. See
/// `TerminalTabBarViewModel` for why.
class TerminalTabBarAccessoryViewController: NSTitlebarAccessoryViewController {
    private let model = TerminalTabBarViewModel()
    private let hostingView: NonDraggableHostingView<TerminalTabBarView>
    private var cancellables: Set<AnyCancellable> = []

    /// Subscriptions to our window, set up once the view is in one.
    private var windowCancellables: Set<AnyCancellable> = []

    /// True when the traffic lights are shown, which is the only thing that
    /// changes how much room we have on the left.
    private let hasWindowButtons: Bool

    /// True when the bar lives in the titlebar itself rather than in its own
    /// row below it. `macos-titlebar-style = tabs` means exactly that, so the
    /// two options compose: one says who implements tabs, the other where the
    /// bar goes.
    private let inTitlebar: Bool

    init(controller: TerminalController) {
        let model = self.model
        model.controller = controller
        model.tabs = controller.tabs
        model.activeIndex = controller.activeTabIndex
        self.hasWindowButtons = controller.derivedConfig.macosWindowButtons == .visible
        self.inTitlebar = controller.derivedConfig.macosTitlebarStyle == .tabs
        model.inTitlebar = self.inTitlebar
        self.hostingView = NonDraggableHostingView(rootView: TerminalTabBarView(model: model))
        model.hostingView = self.hostingView
        super.init(nibName: nil, bundle: nil)

        // `.bottom` is the slot AppKit gives the real `NSTabBar`: a full-width
        // row under the titlebar. `.left` puts us on the titlebar row itself,
        // beside the traffic lights, which is what titlebar tabs are.
        layoutAttribute = inTitlebar ? .left : .bottom

        // This is how `TerminalWindow` recognises us. It has to be set before
        // we are added, because the window reads it as it goes in.
        identifier = TerminalWindow.ownTabBarIdentifier
        view = hostingView
        hostingView.autoresizingMask = [.width]

        controller.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.model.tabs = tabs
                self.model.refreshShortcuts()
                // An accessory view is not autoresized, so its frame has to be
                // kept in step with what the bar actually needs.
                self.resize()
            }
            .store(in: &cancellables)

        controller.$activeTabIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in self?.model.activeIndex = index }
            .store(in: &cancellables)

        model.refreshShortcuts()
        resize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindow()
        syncKeyWindow()
        resize()
    }

    /// Push new colors and font into the bar. Called from `syncAppearance`.
    func update(backgroundColor: NSColor, font: Font) {
        model.backgroundColor = backgroundColor
        model.isLightBackground = backgroundColor.isLightColor
        model.hasVeryDarkBackground = backgroundColor.isVeryDarkColor
        model.font = font
        resize()
    }

    /// Recompute the `goto_tab:N` labels. Called from `relabelTabs`.
    func refreshShortcuts() {
        model.refreshShortcuts()
    }

    // MARK: Window

    private func observeWindow() {
        guard windowCancellables.isEmpty, view.window != nil else { return }
        let center = NotificationCenter.default

        // Subscribed to every window and matched in the handler, the way
        // `SurfaceView` does it. Naming the window as the publisher's `object`
        // would have it hold the window, and the window holds this accessory,
        // so neither would ever be released.
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .merge(with: center.publisher(for: NSWindow.didResignKeyNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, isOurs(notification) else { return }
                self.syncKeyWindow()
            }
            .store(in: &windowCancellables)

        // Tabs share the window's width, so they have to be remeasured with it.
        center.publisher(for: NSWindow.didResizeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, isOurs(notification) else { return }
                self.resize()
            }
            .store(in: &windowCancellables)
    }

    /// Whether a window notification is about the window we are in.
    private func isOurs(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow) === view.window
    }

    private func syncKeyWindow() {
        model.isKeyWindow = view.window?.isKeyWindow ?? false
    }

    private func resize() {
        // Tabs share the bar's width the way the native bar's do, so the bar
        // has to know how wide it actually is. Without a window yet, fall back
        // to what the content wants.
        let width: CGFloat
        if let window = view.window {
            // In the titlebar we start after the traffic lights; in our own row
            // we span the window.
            let inset = inTitlebar && hasWindowButtons
                ? TerminalTabBarView.windowButtonsInset
                : 0
            width = max(window.frame.width - inset, 0)
        } else {
            width = hostingView.fittingSize.width
        }

        model.availableWidth = width
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: max(width, 1),
            height: inTitlebar
                ? TerminalTabBarView.titlebarHeight
                : TerminalTabBarView.rowHeight)
    }
}
