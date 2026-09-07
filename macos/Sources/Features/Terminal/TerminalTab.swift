import Combine
import Foundation

/// A single session ("tab") within a terminal window, mirroring
/// `apprt.gtk.Tab` (`src/apprt/gtk/class/tab.zig`).
///
/// A controller always holds at least one tab. Without `macos-non-native-tabs`
/// it holds exactly one, because there a tab is a whole window of its own.
class TerminalTab: NSObject, Identifiable, ObservableObject {
    let id = UUID()

    /// The split tree for this tab.
    ///
    /// The owning controller keeps this in sync with its own `surfaceTree` for
    /// whichever tab is active, so this is always authoritative.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
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

    /// The last title computed from the focused surface, without the override.
    private(set) var computedTitle: String = "👻"

    /// Tracks the title of whichever surface is focused in this tab.
    private var titleCancellable: AnyCancellable?

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>) {
        self.surfaceTree = surfaceTree
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
        titleCancellable = nil

        // Prefer the focused surface, otherwise any surface in the tab so a
        // background tab with no focus history still gets a name.
        guard let surface = focusedSurface ?? surfaces.first else { return }
        titleCancellable = surface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else { return }
                self.computedTitle = title
                self.recomputeTitle()
            }
    }
}
