import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// Two questions with two different answers: whether the rest of the titlebar
/// has to make room, and whether the AppKit workarounds apply.
@MainActor
struct TerminalWindowTabBarTests {
    private func window() -> TerminalWindow {
        TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true)
    }

    private func accessory(
        _ layout: NSLayoutConstraint.Attribute,
        view: NSView
    ) -> NSTitlebarAccessoryViewController {
        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = layout
        controller.view = view
        return controller
    }

    @Test func ourBarIsATabBarButNotTheNativeOne() {
        let bar = accessory(.bottom, view: NSHostingView(rootView: Text("tabs")))
        bar.identifier = TerminalWindow.ownTabBarIdentifier

        #expect(window().isTabBar(bar))
        #expect(!window().isNativeTabBar(bar))
    }

    // AppKit adds an empty view first and fills it in later.
    @Test func theEmptyNativePlaceholderIsBothKinds() {
        let bar = accessory(.bottom, view: NSView())

        #expect(window().isNativeTabBar(bar))
        #expect(window().isTabBar(bar))
    }

    @Test func aTaggedNativeBarStaysNative() {
        let bar = accessory(.bottom, view: NSView())
        bar.identifier = TerminalWindow.tabBarIdentifier

        #expect(window().isNativeTabBar(bar))
        #expect(window().isTabBar(bar))
    }

    @Test func anOrdinaryAccessoryIsNeither() {
        let other = accessory(.right, view: NSHostingView(rootView: Text("zoom")))

        #expect(!window().isTabBar(other))
        #expect(!window().isNativeTabBar(other))
    }

    @Test func hasTabBarFollowsWhatIsInstalled() {
        let terminalWindow = window()
        #expect(!terminalWindow.hasTabBar)

        let bar = accessory(.bottom, view: NSHostingView(rootView: Text("tabs")))
        bar.identifier = TerminalWindow.ownTabBarIdentifier
        terminalWindow.addTitlebarAccessoryViewController(bar)
        #expect(terminalWindow.hasTabBar)

        if let index = terminalWindow.titlebarAccessoryViewControllers.firstIndex(of: bar) {
            terminalWindow.removeTitlebarAccessoryViewController(at: index)
        }
        #expect(!terminalWindow.hasTabBar)
    }

    @Test func untitledWindowHasNoTabBar() {
        let terminalWindow = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.closable, .resizable],
            backing: .buffered,
            defer: true)
        #expect(!terminalWindow.hasTabBar)
    }

    @Test func removingTitlebarRemovesTabBar() {
        let terminalWindow = window()
        let bar = accessory(.bottom, view: NSHostingView(rootView: Text("tabs")))
        bar.identifier = TerminalWindow.ownTabBarIdentifier
        terminalWindow.addTitlebarAccessoryViewController(bar)
        #expect(terminalWindow.hasTabBar)

        terminalWindow.styleMask.remove(.titled)
        #expect(!terminalWindow.hasTabBar)

        terminalWindow.styleMask.insert(.titled)
        terminalWindow.addTitlebarAccessoryViewController(bar)
        #expect(terminalWindow.hasTabBar)
    }
}
