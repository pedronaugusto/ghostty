import Testing
@testable import Ghostty

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
        #expect(TerminalController.activeIndex(movingFrom: from, to: to, active: active) == expected)
    }

    @Test(arguments: [
        // Ordinary moves within the list.
        (0, 1, 4, 1),
        (3, -1, 4, 2),
        (1, 2, 4, 3),

        // Bounded at both ends rather than wrapping or trapping.
        (3, 5, 4, 3),
        (0, -5, 4, 0),

        // `move_tab` takes an `isize`, so these are legal bindings. Adding
        // before bounding overflows on both, and `-Int.min` traps on its own.
        (0, Int.max, 4, 3),
        (3, Int.min, 4, 0),
        (2, Int.max, 5, 4),
        (2, Int.min, 5, 0),
    ])
    func destinationIsBounded(from: Int, amount: Int, count: Int, expected: Int) {
        #expect(
            TerminalController.destination(movingFrom: from, by: amount, count: count)
                == expected)
    }

    @Test func matchesRemoveAndInsert() {
        let count = 5
        for from in 0..<count {
            for to in 0..<count where to != from {
                for active in 0..<count {
                    var tabs = Array(0..<count)
                    let selected = tabs[active]
                    tabs.insert(tabs.remove(at: from), at: to)

                    let index = TerminalController.activeIndex(
                        movingFrom: from, to: to, active: active)
                    #expect(tabs[index] == selected)
                }
            }
        }
    }
}
