import AppKit
import SwiftUI

/// State for our tab bar, owned by AppKit and observed by SwiftUI.
///
/// This exists so the bar never holds its controller strongly. The window
/// retains its titlebar accessory and an `NSWindowController` retains its
/// window, so a strong reference back from the accessory would keep the whole
/// window alive forever after it closes.
class TerminalTabBarViewModel: ObservableObject {
    /// True when the bar is in the titlebar rather than its own row below it.
    /// That changes how much vertical room we have.
    @Published var inTitlebar: Bool = false

    @Published var tabs: [TerminalTab] = []
    @Published var activeIndex: Int = 0

    /// Keyboard shortcuts for `goto_tab:N`. Only the first nine tabs can have
    /// one, matching the native bar.
    @Published var shortcuts: [UUID: String] = [:]

    /// The tab being dragged, so we can draw it lifted while it slides.
    @Published var draggingTabID: UUID?

    /// The tab under the cursor, if any. We hide the divider next to it, the
    /// same way we do next to the selected tab.
    @Published var hoveredTabID: UUID?

    /// True while our window is key. The native bar lets the selection and the
    /// "+" glyph recede when the window isn't, so we do the same.
    @Published var isKeyWindow: Bool = true

    /// The view hosting the bar. Weak for the same reason `controller` is.
    weak var hostingView: NSView?

    /// How far the tabs have scrolled inside the track.
    ///
    /// A drop location reaches us in the track's coordinates rather than the
    /// tabs', so this is what turns one into the other. We have to ask AppKit
    /// for it: SwiftUI scrolls with an `NSScrollView` underneath and its own
    /// layout never moves, so a `GeometryReader` on the tabs always says zero.
    var trackScrollX: CGFloat {
        trackScrollView?.contentView.bounds.origin.x ?? 0
    }

    /// The scroll view holding the tabs.
    private var trackScrollView: NSScrollView? {
        hostingView?.firstDescendant(ofType: NSScrollView.self)
    }

    /// Width available to the whole bar. Tabs share it the way the native
    /// bar's do, rather than each taking a fixed slot.
    @Published var availableWidth: CGFloat = 0

    /// Which appearance we composite for. The second is whether the background
    /// is dark enough that the pre-macOS-26 bar has to paint the selected tab
    /// rather than let the titlebar show through.
    @Published var isLightBackground: Bool = false
    @Published var hasVeryDarkBackground: Bool = false

    @Published var backgroundColor: NSColor = .windowBackgroundColor
    @Published var font: Font = .system(size: 12)

    /// Weak by design. See the type's documentation.
    weak var controller: TerminalController?

    /// The controller's tab list rather than the copy SwiftUI renders.
    ///
    /// `tabs` reaches us a runloop turn late because `@Published` fires in
    /// `willSet`. That's fine for drawing and far too stale to place a drop.
    var liveTabs: [TerminalTab] {
        controller?.tabs ?? tabs
    }

    // MARK: Colors

    /// One layer of the bar's chrome.
    ///
    /// The native bar composites a gray over the titlebar rather than filling
    /// with a system color. That is what lets it follow any theme, including a
    /// background set at runtime via OSC 11. So a layer for us is that gray and
    /// the opacity we composite it at. The two appearances use different
    /// materials, so each layer carries a pair.
    ///
    /// We read the values off the real tab bar rendered by this app, against
    /// backgrounds spanning the luminance range (macOS 26.2, Sep 2026).
    struct Material {
        let dark: Layer
        let light: Layer

        /// `gray` is 0-255, the scale it was measured on.
        struct Layer {
            let gray: CGFloat
            let opacity: CGFloat
        }
    }

    /// How much we lift the background's chroma before compositing a layer
    /// over it.
    ///
    /// Compositing the gray straight over the background washes the color out:
    /// on a blue background the track comes out gray rather than a darker blue.
    /// This is the multiplier that puts us back on the native bar's pixels.
    /// Over Catppuccin Mocha's `#1e1e2e` our track reads (43, 43, 54) against
    /// the native bar's (42, 42, 54), and the selected tab reads (72, 72, 82)
    /// in both (macOS 26.2, Sep 2026). A gray background hides the difference
    /// entirely, so it takes a themed one to see.
    private static let backdropSaturation: CGFloat = 1.5

    /// What a layer resolves to over this window's background.
    func fill(_ material: Material) -> Color {
        let layer = isLightBackground ? material.light : material.dark
        let value = layer.gray / 255
        guard let background = backgroundColor.usingColorSpace(.sRGB) else {
            return Color(red: value, green: value, blue: value)
        }

        let luminance = background.luminance
        func component(_ channel: CGFloat) -> Double {
            let saturated = luminance + Self.backdropSaturation * (channel - luminance)
            return Double(min(max(saturated, 0), 1) * (1 - layer.opacity) + value * layer.opacity)
        }

        return Color(
            red: component(background.redComponent),
            green: component(background.greenComponent),
            blue: component(background.blueComponent))
    }

    // MARK: Actions

    func select(_ tab: TerminalTab) {
        controller?.selectTab(tab)
    }

    func close(_ tab: TerminalTab) {
        controller?.closeTab(tab)
    }

    func newTab() {
        controller?.newTab(nil)
    }

    func resetZoom(_ tab: TerminalTab) {
        guard let controller else { return }
        controller.selectTab(tab)
        controller.splitZoom(controller)
    }

    // MARK: Context Menu Actions

    // These name the tab that was right-clicked rather than working off the
    // active one, so a background tab's menu closes what it says it will.

    func closeOthers(_ tab: TerminalTab) {
        controller?.closeOtherTabs(keeping: tab)
    }

    func closeToTheRight(_ tab: TerminalTab) {
        controller?.closeTabsOnTheRight(after: tab)
    }

    func hasTabsToTheRight(_ tab: TerminalTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        return index + 1 < tabs.count
    }

    func rename(_ tab: TerminalTab) {
        guard let controller else { return }
        controller.selectTab(tab)
        controller.promptTabTitle(for: tab)
    }

    /// Commit an in-place rename. An empty title restores the computed one,
    /// matching what the `Change Tab Title` sheet does with a blank field.
    func setTitleOverride(_ title: String, for tab: TerminalTab) {
        controller?.setTitleOverride(title.isEmpty ? nil : title, for: tab)
    }

    func setColor(_ color: TerminalTabColor, for tab: TerminalTab) {
        controller?.setTabColor(color, for: tab)
    }

    // MARK: Dragging

    /// Take a tab dropped on this bar, from this window or another one.
    func accept(_ tab: TerminalTab, at index: Int) {
        controller?.accept(tab, at: index)
    }

    /// Keeps the track moving while a drag sits at one of its ends.
    private var edgeScrollTimer: Timer?

    /// Which way we're scrolling, and where the cursor was when we were last
    /// told. Both are refreshed on every drop update rather than captured, so
    /// a drag that crosses to the other end turns around.
    private var edgeScrollDirection: CGFloat = 0
    private var edgeScrollLocation: CGPoint = .zero

    /// What to re-run after each step. See `edgeScroll(at:onScroll:)` for why
    /// this lives here rather than inside the timer's block.
    private var edgeScrollAction: ((CGPoint) -> Void)?

    /// How close to an end starts the track moving, and how far each step goes.
    private static let edgeScrollMargin: CGFloat = 24
    private static let edgeScrollStep: CGFloat = 4

    /// Scroll the track while the cursor is near one of its ends.
    ///
    /// The native bar does this. Without it a drag can only reach the tabs that
    /// are already on screen, so on an overflowing bar most positions are
    /// unreachable. `onScroll` runs after each step so the dragged tab keeps
    /// following the tabs moving under it.
    ///
    /// `onScroll` is held on this model until the drag ends, so it must not
    /// capture the model strongly. `stopEdgeScroll` releases it.
    func edgeScroll(at location: CGPoint, onScroll: @escaping (CGPoint) -> Void) {
        guard let scrollView = trackScrollView else { return stopEdgeScroll() }

        let visible = scrollView.contentView.bounds.width
        if location.x < Self.edgeScrollMargin {
            edgeScrollDirection = -1
        } else if location.x > visible - Self.edgeScrollMargin {
            edgeScrollDirection = 1
        } else {
            return stopEdgeScroll()
        }
        edgeScrollLocation = location
        edgeScrollAction = onScroll

        // A drag can sit still at the end, so this has to keep going on its own
        // rather than wait for the next drop update.
        guard edgeScrollTimer == nil else { return }
        edgeScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.advanceEdgeScroll()
        }
    }

    private func advanceEdgeScroll() {
        guard let scrollView = trackScrollView else { return stopEdgeScroll() }

        let content = scrollView.documentView?.frame.width ?? 0
        let furthest = max(content - scrollView.contentView.bounds.width, 0)
        let current = scrollView.contentView.bounds.origin.x
        let next = min(max(current + edgeScrollDirection * Self.edgeScrollStep, 0), furthest)
        guard next != current else { return }

        scrollView.contentView.scroll(to: NSPoint(x: next, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // The cursor hasn't moved, but the content under it has, so the drop
        // position it names is a new one every step.
        edgeScrollAction?(edgeScrollLocation)
    }

    func stopEdgeScroll() {
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
        edgeScrollAction = nil
    }

    deinit {
        edgeScrollTimer?.invalidate()
    }

    // MARK: Rendering

    /// Whether a divider is drawn after the given tab.
    ///
    /// The native bar drops the divider on both sides of the selected tab and
    /// of whichever tab the cursor is over, so a divider only ever separates
    /// two tabs that are neither.
    func showsDivider(after tab: TerminalTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }),
              index + 1 < tabs.count else { return false }
        return ![index, index + 1].contains {
            $0 == activeIndex || tabs[$0].id == hoveredTabID
        }
    }

    func shortcut(for tab: TerminalTab) -> String? {
        shortcuts[tab.id]
    }

    /// Recompute the `goto_tab:N` shortcut labels.
    ///
    /// This is our equivalent of `TerminalController.relabelTabs`, which
    /// writes the same strings into each native tab's accessory view.
    @MainActor
    func refreshShortcuts() {
        guard let config = controller?.ghostty.config else {
            shortcuts = [:]
            return
        }

        shortcuts = tabs.prefix(9).enumerated().reduce(into: [:]) { result, element in
            let (index, tab) = element
            guard let equiv = config.keyboardShortcut(for: "goto_tab:\(index + 1)") else { return }
            result[tab.id] = "\(equiv)"
        }
    }
}
