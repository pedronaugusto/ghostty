import Testing
@testable import Ghostty

/// Where the selection lands when a tab is dragged to a new position.
///
/// A drag in the tab bar reorders live, so this runs on every mouse move and a
/// wrong answer is a selection that jumps around under the cursor.
@Suite
struct TerminalTabOrderingTests {
    @Test(arguments: [
        // The dragged tab is the selected one: the selection goes with it.
        (0, 2, 0, 2),
        (2, 0, 2, 0),

        // Dragged from before the selection to after it: everything between
        // shifts down one.
        (0, 2, 1, 0),
        (0, 3, 2, 1),

        // Dragged from after the selection to before it: shifts up one.
        (2, 0, 1, 2),
        (3, 0, 1, 2),

        // The move happened entirely on one side of the selection.
        (0, 1, 3, 3),
        (2, 3, 1, 1),
    ])
    func activeIndexAfterMove(from: Int, to: Int, active: Int, expected: Int) {
        #expect(BaseTerminalController.activeIndex(movingFrom: from, to: to, active: active) == expected)
    }

    /// Moving a tab is a removal and an insertion, so the arithmetic has to
    /// agree with actually doing that to an array.
    @Test func matchesRemoveAndInsert() {
        let count = 5
        for from in 0..<count {
            for to in 0..<count where to != from {
                for active in 0..<count {
                    var tabs = Array(0..<count)
                    let selected = tabs[active]
                    tabs.insert(tabs.remove(at: from), at: to)

                    let index = BaseTerminalController.activeIndex(
                        movingFrom: from, to: to, active: active)
                    #expect(tabs[index] == selected)
                }
            }
        }
    }
}
