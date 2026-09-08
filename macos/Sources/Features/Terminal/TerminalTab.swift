import Combine
import Foundation

/// A single session ("tab") within a terminal window: a split tree plus the
/// title and color the tab bar shows for it.
///
/// A controller holds one of these per session. Without `macos-non-native-tabs`
/// it holds exactly one, because there a tab is a whole window of its own.
class TerminalTab: NSObject, Identifiable, ObservableObject {
    let id = UUID()

    /// The split tree for this tab.
    ///
    /// `TerminalController.setSurfaceTree(_:for:)` is the only writer, apart
    /// from initialization and the controller's active-tree mirror, so every
    /// change keeps ownership, observers, and restorable state in step.
    fileprivate(set) var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        didSet { isZoomed = surfaceTree.zoomed != nil }
    }

    /// The surface that had focus in this tab when it was last active. Weak
    /// because `surfaceTree` is what actually owns the surfaces.
    weak var focusedSurface: Ghostty.SurfaceView?

    /// A title set explicitly by the user via `prompt_tab_title`. When set this
    /// takes precedence over the computed title.
    var titleOverride: String? {
        didSet { recomputeTitle() }
    }

    /// The title shown in the tab bar.
    @Published private(set) var title: String = "👻"

    /// True when any surface in this tab has an active bell.
    @Published var bell: Bool = false

    /// The user-assigned color for this tab, if any.
    @Published var tabColor: TerminalTabColor = .none

    /// True when a split in this tab is zoomed, so the bar can offer the same
    /// reset-zoom button the native tab accessory does.
    @Published private(set) var isZoomed: Bool = false

    /// Whether this session can be restored.
    ///
    /// False for a tab opened with a command to execute: what would come back
    /// is a shell in the command's directory, which is meaningless. Upstream
    /// decides this once per window because there a window is a session; here
    /// a window holds many, so it belongs to the tab. See
    /// `TerminalController.restorable`.
    let restorable: Bool

    /// The last title computed from the focused surface, without the override.
    private(set) var computedTitle: String = "👻"

    /// Tracks the title of whichever surface is focused in this tab.
    private var titleCancellable: AnyCancellable?

    /// The surface `titleCancellable` is watching.
    ///
    /// We can't just look at `focusedSurface` for this. If the tab has no focus
    /// history we observe the first surface instead, and then we have nothing
    /// telling us which surface that was.
    private(set) weak var observedSurface: Ghostty.SurfaceView?

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, restorable: Bool = true) {
        self.surfaceTree = surfaceTree
        self.restorable = restorable
        self.isZoomed = surfaceTree.zoomed != nil
        super.init()
        observeTitle()
    }

    /// Every surface in this tab.
    var surfaces: [Ghostty.SurfaceView] {
        Array(surfaceTree)
    }

    private func recomputeTitle() {
        let newValue = titleOverride ?? computedTitle
        guard newValue != title else { return }
        title = newValue
    }

    /// Rebind the title observer to the currently focused surface, which is the
    /// only writer of the computed title. The controller separately derives the
    /// window title from the same surface.
    func observeTitle() {
        // Prefer the focused surface, otherwise any surface in the tab so a
        // background tab with no focus history still gets a name.
        let target = focusedSurface ?? surfaces.first
        guard target !== observedSurface else { return }

        titleCancellable = nil
        observedSurface = target
        guard let surface = target else { return }
        titleCancellable = surface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else { return }
                self.computedTitle = title
                self.recomputeTitle()
            }
    }
}

/// The only writers of `TerminalTab.surfaceTree`.
///
/// They live here rather than with the rest of `TerminalController` so that
/// `fileprivate(set)` restricts writes to this file, and this is where the
/// window's bookkeeping for a changed tree is done.
extension TerminalController {
    /// Give a tab a new split tree, going through `surfaceTree` while it is the
    /// active tab so the controller and what is on screen stay in step.
    ///
    /// The tab may have moved to another window since a caller captured it, so
    /// this always writes through whichever controller holds it now.
    static func setSurfaceTree(_ tree: SplitTree<Ghostty.SurfaceView>, for tab: TerminalTab) {
        guard let controller = controller(owning: tab) else {
            tab.surfaceTree = tree
            return
        }

        if tab === controller.activeTab {
            controller.surfaceTree = tree
        } else {
            let oldTree = tab.surfaceTree
            tab.surfaceTree = tree
            controller.backgroundTabTreeDidChange(tab, from: oldTree, to: tree)
        }
    }

    /// Mirror the controller's `surfaceTree` into the active tab. Called only
    /// from that property's `didSet`, which is what keeps the two in step.
    func syncActiveTabSurfaceTree() {
        activeTab?.surfaceTree = surfaceTree
    }
}
