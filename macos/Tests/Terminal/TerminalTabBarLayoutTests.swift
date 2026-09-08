import Testing
import AppKit
@testable import Ghostty

struct TerminalTabBarLayoutTests {
    @Test(arguments: [
        (CGFloat(831), 2, CGFloat(415.5)),
        (CGFloat(831), 4, CGFloat(207.75)),
        (CGFloat(831), 6, CGFloat(138.5)),
    ])
    func sharesTheTrackEvenly(track: CGFloat, count: Int, expected: CGFloat) {
        #expect(TerminalTabBarView.tabWidth(track: track, count: count) == expected)
    }

    @Test(arguments: [7, 12, 20, 100])
    func holdsTheFloorAndOverflows(count: Int) {
        let track: CGFloat = 831
        let width = TerminalTabBarView.tabWidth(track: track, count: count)
        #expect(width == TerminalTabBarView.minTabWidth)

        // Held at the floor the tabs no longer fit, which is the whole reason
        // the track has to scroll.
        #expect(width * CGFloat(count) > track)
    }

    // The native bar holds at 120, so an 831 point track fits six tabs.
    @Test func startsScrollingAtSevenTabs() {
        let track: CGFloat = 831
        #expect(TerminalTabBarView.tabWidth(track: track, count: 6) * 6 <= track)
        #expect(TerminalTabBarView.tabWidth(track: track, count: 7) * 7 > track)
    }

    @Test(arguments: [nil, CGFloat(0), CGFloat(-10)])
    func fallsBackToTheFloorWithoutATrack(track: CGFloat?) {
        #expect(TerminalTabBarView.tabWidth(track: track, count: 3) == TerminalTabBarView.minTabWidth)
    }

    @Test func reorderStopsAtTheLastTab() {
        let width: CGFloat = 120
        for slot in 0..<5 {
            let x = CGFloat(slot) * width + width / 2
            #expect(TerminalTabDropDelegate.reorderIndex(at: x, tabWidth: width, count: 5) == slot)
        }

        // Past the end, and before the start.
        #expect(TerminalTabDropDelegate.reorderIndex(at: 5000, tabWidth: width, count: 5) == 4)
        #expect(TerminalTabDropDelegate.reorderIndex(at: -20, tabWidth: width, count: 5) == 0)
    }

    // A tab arriving from another window has one more position than a reorder
    // does, because it can go after all of them.
    @Test func insertionReachesTheEnd() {
        let width: CGFloat = 120
        #expect(TerminalTabDropDelegate.insertionIndex(at: 5 * width - 1, tabWidth: width, count: 5) == 5)
        #expect(TerminalTabDropDelegate.insertionIndex(at: 5000, tabWidth: width, count: 5) == 5)
    }

    @Test func insertionSplitsOnTheMidpoint() {
        let width: CGFloat = 120
        for slot in 0..<5 {
            let left = CGFloat(slot) * width + 1
            let right = CGFloat(slot) * width + width - 1
            #expect(TerminalTabDropDelegate.insertionIndex(at: left, tabWidth: width, count: 5) == slot)
            #expect(TerminalTabDropDelegate.insertionIndex(at: right, tabWidth: width, count: 5) == slot + 1)
        }
    }

    @Test func handlesAnEmptyBar() {
        #expect(TerminalTabDropDelegate.reorderIndex(at: 40, tabWidth: 120, count: 0) == 0)
        #expect(TerminalTabDropDelegate.insertionIndex(at: 40, tabWidth: 120, count: 0) == 0)
        #expect(TerminalTabDropDelegate.reorderIndex(at: 40, tabWidth: 0, count: 5) == 0)
        #expect(TerminalTabDropDelegate.insertionIndex(at: 40, tabWidth: 0, count: 5) == 0)
    }
}
