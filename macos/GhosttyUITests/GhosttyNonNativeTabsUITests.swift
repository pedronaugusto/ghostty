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

    /// Double-clicking a tab must open the inline editor and leave the window
    /// answering.
    ///
    /// Focusing a SwiftUI `TextField` inside our titlebar accessory used to
    /// send AppKit's autofill heuristic walking the window's key-view loop
    /// through the hosting view, wedging the main thread for hours. Nothing
    /// caught it: the live checks drive the `Change Tab Title...` menu item,
    /// whose `NSAlert` is a separate window, and no test had ever
    /// double-clicked a tab. Every assertion here is a bounded wait, so a
    /// wedged app fails this in seconds rather than stalling the whole run.
    @MainActor
    func testDoubleClickRenameLeavesTheWindowResponsive() throws {
        let app = try ghosttyApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should exist")

        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "The terminal surface should exist")
        pane.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForTabs(app, toEqual: 2), "There should be 2 tabs")

        // Rename the tab that is not selected, so a rename applied to the wrong
        // tab is visible rather than masked.
        let target = tabs(in: app).element(boundBy: 0)
        let other = tabs(in: app).element(boundBy: 1)
        let originalOtherLabel = other.label
        target.doubleClick()

        // The first assertion after the double click is the regression guard.
        // A wedged main thread answers no queries, so this fails on timeout.
        let editor = window.textFields.firstMatch
        XCTAssertTrue(
            editor.waitForExistence(timeout: 10),
            "Double-clicking a tab should open the inline editor and the window should still answer")

        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("zqx\r")

        let renamed = NSPredicate(format: "label == %@", "zqx")
        expectation(for: renamed, evaluatedWith: target)
        waitForExpectations(timeout: 10)

        XCTAssertEqual(
            other.label, originalOtherLabel,
            "Only the double-clicked tab should have been renamed")

        // Still answering after the commit, which is the other half of the
        // walk: the editor leaving the view tree releases first responder.
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 5),
            "The window should still answer after the rename is committed")

        assertTerminalHasFocus(in: app, after: "Return")
    }

    /// Shift-Tab ends editing with a backtab movement, after which AppKit asks
    /// the field for its *previous* valid key view. That is the same visual
    /// key-view computation the autofill heuristic triggers, through the other
    /// door, so it needs its own guard.
    @MainActor
    func testShiftTabCommitsRenameAndLeavesTheWindowResponsive() throws {
        let app = try ghosttyApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should exist")

        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "The terminal surface should exist")
        pane.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForTabs(app, toEqual: 2), "There should be 2 tabs")

        let target = tabs(in: app).element(boundBy: 0)
        target.doubleClick()
        let editor = window.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Double-clicking a tab should open the inline editor")

        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("zqx")
        editor.typeKey(.tab, modifierFlags: .shift)

        // The regression guard: a wedged main thread answers no queries.
        let renamed = NSPredicate(format: "label == %@", "zqx")
        expectation(for: renamed, evaluatedWith: target)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(window.textFields.firstMatch.exists, "Shift-Tab should have closed the editor")

        assertTerminalHasFocus(in: app, after: "Shift-Tab")
    }

    /// After a rename ends, the editor must be gone and the terminal reachable
    /// again -- the visible half of "focus went back to the terminal".
    ///
    /// The definitive proof that keyboard focus returns to the surface is the
    /// `renamefocus` live check, which reads `kAXFocusedUIElementAttribute`
    /// directly and confirms it is the terminal's `AXTextArea` in both the
    /// default and the titlebar row. XCUITest cannot read first responder, and
    /// typing into the shell to observe it back is too timing-dependent to gate
    /// CI on, so this asserts the robust, observable signals instead.
    private func assertTerminalHasFocus(in app: XCUIApplication, after how: String) {
        XCTAssertFalse(
            app.windows.firstMatch.textFields.firstMatch.exists,
            "After ending the rename with \(how) the inline editor should be gone")
        let pane = app.groups["Terminal pane"].firstMatch
        XCTAssertTrue(
            pane.waitForExistence(timeout: 5) && pane.isHittable,
            "After ending the rename with \(how) the terminal surface should be reachable again")
    }
}
