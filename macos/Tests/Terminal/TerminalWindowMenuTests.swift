import AppKit
import Testing
@testable import Ghostty

/// AppKit contributes "Move Tab to New Window" and "Merge All Windows" itself,
/// but only while window tabbing is available, so with Ghostty-owned tabs they
/// are built as the menu opens instead.
struct TerminalWindowMenuTests {
    // A stand-in for the Window menu: the items around where ours land.
    @MainActor
    private func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(
            title: "Toggle Full Screen",
            action: NSSelectorFromString("toggleGhosttyFullScreen:"),
            keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Show/Hide All Terminals",
            action: NSSelectorFromString("toggleVisibility:"),
            keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Zoom Split",
            action: NSSelectorFromString("splitZoom:"),
            keyEquivalent: ""))
        return menu
    }

    @MainActor
    @Test func addsBothItemsAfterShowHideAllTerminals() throws {
        let menu = makeWindowMenu()
        let target = NSObject()
        TerminalWindow.configureWindowMenu(menu, target: target)

        let titles = menu.items.map(\.title)
        let anchor = try #require(titles.firstIndex(of: "Show/Hide All Terminals"))
        #expect(titles[anchor + 1] == "Move Tab to New Window")
        #expect(titles[anchor + 2] == "Merge All Windows")

        // They must land above the separator, not under the window list AppKit
        // keeps at the bottom.
        let separator = try #require(menu.items.firstIndex(where: { $0.isSeparatorItem }))
        #expect(separator > anchor + 2)

        for item in menu.items where item.title.hasSuffix("Window") || item.title.hasSuffix("Windows") {
            #expect(item.target === target)
        }
    }

    @MainActor
    @Test func removesBothItemsWithoutATarget() throws {
        let menu = makeWindowMenu()
        TerminalWindow.configureWindowMenu(menu, target: NSObject())
        TerminalWindow.configureWindowMenu(menu, target: nil)

        let titles = menu.items.map(\.title)
        #expect(!titles.contains("Move Tab to New Window"))
        #expect(!titles.contains("Merge All Windows"))
    }

    @MainActor
    @Test func repeatedConfigurationDoesNotDuplicate() throws {
        let menu = makeWindowMenu()
        let before = menu.items.count
        for _ in 0..<5 {
            TerminalWindow.configureWindowMenu(menu, target: NSObject())
        }
        #expect(menu.items.count == before + 2)
    }

    /// The commands belong to whichever window is key. Anything that is not a
    /// terminal drawing its own tabs gets none, which is what clears them when
    /// the About panel or another app's window takes key.
    @MainActor
    @Test func windowMenuCommandsBelongToTheKeyWindow() {
        #expect(TerminalWindow.windowMenuTarget(for: nil) == nil)

        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true)
        #expect(TerminalWindow.windowMenuTarget(for: plain) == nil)

        // One of ours, but with no controller behind it, so still nothing.
        let terminalWindow = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true)
        #expect(TerminalWindow.windowMenuTarget(for: terminalWindow) == nil)
    }

    @MainActor
    @Test func doesNothingWithoutTheAnchorItem() throws {
        let menu = NSMenu(title: "Window")
        menu.addItem(NSMenuItem(title: "Minimize", action: nil, keyEquivalent: ""))
        TerminalWindow.configureWindowMenu(menu, target: NSObject())
        #expect(menu.items.count == 1)
    }
}
