import AppKit
import SwiftUI

/// State for Ghostty's own tab bar, owned by AppKit and observed by SwiftUI.
///
/// This exists so the bar never holds its controller strongly: the window
/// retains its titlebar accessory, and an `NSWindowController` retains its
/// window, so a strong reference back to the controller from the accessory
/// would keep the whole window alive forever after it closes.
class TerminalTabBarViewModel: ObservableObject {
    /// True when the bar is in the titlebar rather than its own row below it,
    /// which changes how much vertical room it has.
    @Published var inTitlebar: Bool = false

    @Published var tabs: [TerminalTab] = []
    @Published var activeIndex: Int = 0

    /// Keyboard shortcuts for `goto_tab:N`. Only the first nine tabs can have
    /// one, matching the native bar.
    @Published var shortcuts: [UUID: String] = [:]

    /// The tab being dragged, so it can be drawn lifted while it slides.
    @Published var draggingTabID: UUID?

    /// The tab under the cursor, if any. A divider is hidden next to it the
    /// same way it is hidden next to the selected tab.
    @Published var hoveredTabID: UUID?

    /// True while our window is key. The native bar dims its whole chrome when
    /// the window isn't, so we do the same.
    @Published var isKeyWindow: Bool = true

    /// Width available to the whole bar, so tabs can share it the way the
    /// native bar does rather than each taking a fixed slot.
    @Published var availableWidth: CGFloat = 0

    /// Which appearance the bar composites for, and whether the background is
    /// dark enough that the pre-macOS-26 bar has to paint the selected tab
    /// rather than leave the titlebar showing through.
    @Published var isLightBackground: Bool = false
    @Published var hasVeryDarkBackground: Bool = false

    @Published var backgroundColor: NSColor = .windowBackgroundColor
    @Published var font: Font = .system(size: 12)

    /// Weak by design. See the type's documentation.
    weak var controller: TerminalController?

    /// The controller's tab list rather than the copy SwiftUI renders.
    ///
    /// `tabs` is delivered a runloop turn late, because `@Published` fires in
    /// `willSet`. That is fine for drawing and far too stale to place a drop.
    var liveTabs: [TerminalTab] {
        controller?.tabs ?? tabs
    }

    // MARK: Colors

    /// One layer of the bar's chrome.
    ///
    /// The native bar composites a gray over the titlebar rather than filling
    /// with a system color, which is what lets it follow any theme, including a
    /// background set at runtime via OSC 11. A layer is therefore that gray and
    /// the opacity it is composited at. The two appearances composite different
    /// materials, so each layer carries a pair.
    ///
    /// The values are read off the real tab bar rendered by this app, against
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

    /// How much the native bar boosts the chroma of what it samples before
    /// blending, the way an `NSVisualEffectView` material does.
    ///
    /// Without this the chrome washes the color out of a themed background: on
    /// a blue background the track comes out gray rather than a darker blue.
    /// A gray background makes this invisible, which is why it takes a themed
    /// one to see.
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

    // The close actions all work off the active tab, exactly as the native ones
    // work off the right-clicked window, so selecting first is what makes "this
    // tab" mean the tab that was clicked.

    func closeOthers(_ tab: TerminalTab) {
        guard let controller else { return }
        controller.selectTab(tab)
        controller.closeOtherTabs(nil)
    }

    func closeToTheRight(_ tab: TerminalTab) {
        guard let controller else { return }
        controller.selectTab(tab)
        controller.closeTabsOnTheRight(nil)
    }

    func hasTabsToTheRight(_ tab: TerminalTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        return index + 1 < tabs.count
    }

    func moveToNewWindow(_ tab: TerminalTab) {
        controller?.moveTabToNewWindow(tab)
    }

    func rename(_ tab: TerminalTab) {
        guard let controller else { return }
        controller.selectTab(tab)
        controller.promptTabTitle()
    }

    /// Commit an in-place rename. An empty title restores the computed one,
    /// matching what the `Change Tab Title` sheet does with a blank field.
    func setTitleOverride(_ tab: TerminalTab, _ title: String) {
        guard let controller else { return }
        let override: String? = title.isEmpty ? nil : title

        // The controller owns the active tab's override because it also drives
        // the window title; background tabs own their own.
        if tab === controller.activeTab {
            controller.titleOverride = override
        } else {
            tab.titleOverride = override
        }

        controller.invalidateRestorableState()
    }

    func setColor(_ tab: TerminalTab, _ color: TerminalTabColor) {
        controller?.setTabColor(color, for: tab)
    }

    // MARK: Dragging

    /// Take a tab dropped on this bar, from this window or another one.
    func accept(_ tab: TerminalTab, at index: Int) {
        controller?.accept(tab, at: index)
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
    /// This is the non-native-tab equivalent of `TerminalController.relabelTabs`,
    /// which writes the same strings into each native tab's accessory view.
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
