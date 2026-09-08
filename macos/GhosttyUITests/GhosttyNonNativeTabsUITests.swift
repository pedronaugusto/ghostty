import XCTest

/// The tab bar we draw ourselves with `macos-non-native-tabs`.
///
/// SwiftUI can't publish an `NSAccessibility` tab role, so unlike
/// `GhosttyTitlebarTabsUITests` these can't go through `app.tabs`. We find our
/// tabs by the identifiers the bar sets instead.
final class GhosttyNonNativeTabsUITests: GhosttyCustomConfigCase {
    /// The width a tab stops shrinking at, from `TerminalTabBarView`. We can't
    /// import it here, so a tab this wide is how we know the track is full.
    private let minTabWidth: CGFloat = 120

    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            macos-non-native-tabs = true
            window-show-tab-bar = always
            confirm-close-surface = false
            title = "GhosttyNonNativeTabsUITests"
            """
        )
    }

    private func tabs(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "_ghosttyTab")
    }

    private func waitForTabs(_ app: XCUIApplication, toEqual count: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tabs(in: app).count == count { return true }
            usleep(200_000)
        }

        return tabs(in: app).count == count
    }

    @MainActor
    func testTabsStayInOneWindow() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Main window should exist")

        app.groups["Terminal pane"].firstMatch.typeKey("t", modifierFlags: .command)
        app.groups["Terminal pane"].firstMatch.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(waitForTabs(app, toEqual: 3), "There should be 3 tabs")
        XCTAssertEqual(app.windows.count, 1, "Three tabs should be one window")
    }

    @MainActor
    func testExitedSurfaceInBackgroundTabIsRemoved() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Main window should exist")

        // Arm the first tab to exit, then move off it before it does. The app
        // can't see files at this process's temporary directory, so a delay is
        // the only release we have; asserting the second tab exists first keeps
        // a slow run from passing this by accident.
        let pane = app.groups["Terminal pane"].firstMatch
        pane.typeText("sleep 8; exit\r")
        pane.typeKey("t", modifierFlags: .command)

        XCTAssertEqual(tabs(in: app).count, 2, "The second tab should exist before the first one exits")

        XCTAssertTrue(
            waitForTabs(app, toEqual: 1, timeout: 20),
            "The background tab should go away when its only surface exits")
    }

    @MainActor
    func testZoomedSplitShowsOneResetZoomControl() throws {
        let app = try ghosttyApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should exist")

        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "The terminal surface should exist")

        pane.typeKey("d", modifierFlags: .command)

        // Splitting renames the panes, so "Terminal pane" stops matching. We
        // wait on the split itself and send the next key to the window.
        let split = app.groups["Horizontal split view"].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 10), "The split should exist")
        window.typeKey(.return, modifierFlags: [.command, .shift])

        // Our button only appears once a split is zoomed, so this is also what
        // proves the split and the zoom both happened.
        let ours = window.buttons["_resetZoomButton"].firstMatch
        XCTAssertTrue(ours.waitForExistence(timeout: 5), "Our bar should offer reset zoom while zoomed")

        let controls = window.descendants(matching: .button).matching(
            NSPredicate(
                format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "resetzoom", "resetzoom", "reset zoom"))
        XCTAssertEqual(
            controls.count, 1,
            "Only our bar should offer reset zoom: \(window.debugDescription)")
    }

    @MainActor
    func testTabBarStaysReachablePastOverflow() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Main window should exist")

        let window = app.windows.firstMatch
        let bar = window.descendants(matching: .any).matching(identifier: "_ghosttyTabBar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The tab bar should exist")

        // Enough tabs that they cannot all fit, whatever this window's width is.
        let count = Int((bar.frame.width / minTabWidth).rounded(.up)) + 2
        let pane = app.groups["Terminal pane"].firstMatch
        for _ in 1..<count {
            pane.typeKey("t", modifierFlags: .command)
        }
        XCTAssertTrue(waitForTabs(app, toEqual: count), "There should be \(count) tabs")

        // A tab at the floor is how we know the track really overflowed. If it
        // isn't, this test proved nothing.
        let firstTab = tabs(in: app).element(boundBy: 0)
        XCTAssertEqual(
            firstTab.frame.width, minTabWidth, accuracy: 1,
            "Tabs should be held at their minimum width, otherwise nothing overflowed")

        let newTabButton = window.buttons["_newTabButton"].firstMatch
        XCTAssertTrue(newTabButton.isHittable, "The new tab button should still be reachable")
        XCTAssertTrue(window.frame.contains(newTabButton.frame), "The new tab button should be inside the window")

        // The last tab we made is the selected one, and selecting scrolls it
        // into view, so it has to be inside the bar rather than off the end.
        let selected = tabs(in: app).allElementsBoundByIndex.first { $0.isSelected }
        let selectedTab = try XCTUnwrap(selected, "One tab should be selected")
        XCTAssertTrue(
            bar.frame.insetBy(dx: -1, dy: -1).contains(selectedTab.frame),
            "The selected tab should be scrolled into view: \(selectedTab.frame) not in \(bar.frame)")
    }
}
