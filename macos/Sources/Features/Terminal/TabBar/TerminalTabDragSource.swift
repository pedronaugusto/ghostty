import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag source for a tab in Ghostty's own tab bar.
///
/// This is the tab-level counterpart to `Ghostty.SurfaceDragSource` and works
/// the same way: an AppKit view begins an `NSDraggingSession` carrying the
/// tab's UUID, so a drop can be resolved in any window rather than only the one
/// the drag started in. Going through the pasteboard rather than a SwiftUI
/// gesture is also what gives the drag an image under the cursor, which is what
/// the native tab bar does.
struct TerminalTabDragSource: NSViewRepresentable {
    let tab: TerminalTab

    /// Hover is reported from here rather than SwiftUI's `.onHover`, because
    /// this view sits over the tab and would otherwise swallow it.
    ///
    /// It lives on the model rather than in each tab so exactly one tab is ever
    /// hovered. Live reordering moves these views around under the cursor and
    /// enter/exit do not always arrive in pairs, which with per-tab state
    /// leaves highlights stuck on.
    @ObservedObject var model: TerminalTabBarViewModel

    /// Double-click renames in place. The press lands here rather than on the
    /// SwiftUI tab, so the gesture has to be reported back out.
    let onDoubleClick: () -> Void

    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            model.hoveredTabID = tab.id
        } else if model.hoveredTabID == tab.id {
            model.hoveredTabID = nil
        }
    }

    private func draggingChanged(_ id: UUID?) {
        model.draggingTabID = id
        // A drag suppresses hover, and nothing is hovered when it ends until
        // the cursor moves again.
        model.hoveredTabID = nil
    }

    func makeNSView(context: Context) -> TerminalTabDragSourceView {
        let view = TerminalTabDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TerminalTabDragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: TerminalTabDragSourceView) {
        view.tab = tab
        view.onHoverChanged = hoverChanged
        view.onDraggingChanged = draggingChanged
        view.onDoubleClick = onDoubleClick
    }
}

/// The underlying view that starts the drag.
///
/// It sits over the tab's decoration and under its controls, so the close and
/// reset zoom buttons keep their own clicks while a press anywhere else on the
/// tab selects or drags it.
class TerminalTabDragSourceView: NSView, NSDraggingSource {
    /// The tab being dragged right now, anywhere in the app.
    ///
    /// A drop target needs this to reorder live as the cursor moves, because
    /// the pasteboard payload can only be read asynchronously and that is far
    /// too late to move anything under the cursor. Weak because the tab is
    /// owned by whichever controller currently holds it, which changes mid-drag.
    ///
    /// `BaseTerminalController.surfaceControllers` is app-wide for the same
    /// reason: a drag has to be resolved across windows, and no view hierarchy
    /// spans them.
    static weak var dragging: TerminalTab?

    var tab: TerminalTab?

    /// Callback invoked when the mouse enters or exits this view's bounds.
    var onHoverChanged: ((Bool) -> Void)?

    /// Callback invoked with the dragged tab's ID while a drag is in flight.
    var onDraggingChanged: ((UUID?) -> Void)?

    /// Callback invoked when the tab is double-clicked.
    var onDoubleClick: (() -> Void)?

    /// The image shown under the cursor, used once the drag leaves the bar.
    private var dragImage: NSImage?

    /// Whether the drag is over the bar, so the image is swapped only when
    /// that changes rather than on every mouse move.
    private var dragWasInBar: Bool?

    /// Local event monitor to detect escape key presses during drag.
    private var escapeMonitor: Any?

    /// Whether the current drag was cancelled by pressing escape.
    private var dragCancelledByEscape: Bool = false

    /// Where the tab was when the drag started, so escape can put it back. The
    /// live reorder has already committed by then, possibly into another window.
    private weak var dragOriginController: BaseTerminalController?
    private var dragOriginIndex: Int = 0

    /// Where the press started, so a drag only begins once the cursor has
    /// actually travelled. Without this a click that wobbles by a pixel starts
    /// dragging the tab instead of selecting it.
    private var mouseDownLocation: NSPoint?

    /// How far the cursor must move before this becomes a drag.
    private static let dragThreshold: CGFloat = 6

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Get the mouse before the titlebar's own window-drag handling.
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only take a plain left press. Everything that opens the context menu
        // -- the right button, and control with the left -- belongs to the
        // SwiftUI view underneath.
        guard let event = NSApp.currentEvent else { return super.hitTest(point) }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return nil
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return nil
        default:
            return super.hitTest(point)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        // Selecting on the press rather than the release is what the native bar
        // does, and it is what makes a dragged tab always be the selected one.
        // Consuming the event also stops the titlebar dragging the window.
        mouseDownLocation = event.locationInWindow
        guard let tab, let controller = BaseTerminalController.controller(owning: tab) else { return }
        controller.selectTab(tab)
    }

    override func mouseUp(with event: NSEvent) {
        // Only a press that started here and ended here is a click on this tab.
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        guard event.clickCount == 2,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onDoubleClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let moved = hypot(
            event.locationInWindow.x - start.x,
            event.locationInWindow.y - start.y)
        guard moved >= Self.dragThreshold else { return }
        mouseDownLocation = nil

        guard let tab, let pasteboardItem = tab.pasteboardItem() else { return }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // While the drag stays in the bar the tab slides inside the track and
        // draws itself lifted, which is what the native bar does, so nothing is
        // shown under the cursor. The snapshot is swapped in by `movedTo` once
        // the drag leaves the bar and the tab is really coming out.
        dragImage = snapshot()
        let mouse = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(
                x: mouse.x - bounds.width / 2,
                y: mouse.y - bounds.height / 2,
                width: bounds.width,
                height: bounds.height),
            contents: NSImage(size: .init(width: 1, height: 1)))

        dragCancelledByEscape = false
        dragOriginController = BaseTerminalController.controller(owning: tab)
        dragOriginIndex = dragOriginController?.tabs.firstIndex { $0 === tab } ?? 0
        Self.dragging = tab
        onDraggingChanged?(tab.id)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                self?.dragCancelledByEscape = true
            }
            return event
        }

        let session = beginDraggingSession(with: [item], event: event, source: self)

        // We need to disable this so that endedAt happens immediately for our
        // drags outside of any targets.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// A bitmap of the tab as it is currently drawn.
    ///
    /// This view is transparent, so the pixels have to come from the hosting
    /// view that actually draws the bar.
    private func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var host: NSView? = superview
        while let current = host, !(current is NonDraggableHostingView<TerminalTabBarView>) {
            host = current.superview
        }
        guard let host else { return nil }

        let rect = convert(bounds, to: host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        host.cacheDisplay(in: rect, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        movedTo screenPoint: NSPoint
    ) {
        // Show the tab under the cursor only once it has left the bar, so an
        // in-bar reorder looks like the tab sliding rather than a copy of it
        // floating over the window.
        guard let window else { return }
        let inBar = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero))
            .origin
            .y >= window.contentLayoutRect.maxY
        guard inBar != dragWasInBar else { return }
        dragWasInBar = inBar

        let image = inBar ? NSImage(size: .init(width: 1, height: 1)) : dragImage
        guard let image else { return }
        session.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, _ in
            item.setDraggingFrame(
                NSRect(origin: item.draggingFrame.origin, size: image.size),
                contents: image)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDraggingChanged?(nil)
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        Self.dragging = nil
        dragWasInBar = nil

        guard let tab else { return }

        // Escape snaps the tab back where it started, the way it does with a
        // native tab. The live reorder has already committed by now.
        if dragCancelledByEscape {
            dragOriginController?.accept(tab, at: dragOriginIndex)
            return
        }

        // Dropped on nothing: give the tab a window of its own where it landed,
        // which is what dragging a native tab out does. Same rule as
        // `SurfaceDragSource`.
        guard operation == [] else { return }
        let endsInWindow = NSApp.windows.contains { window in
            window.isVisible && window.frame.contains(screenPoint)
        }
        guard !endsInWindow else { return }

        NotificationCenter.default.post(
            name: .ghosttyTabDragEndedNoTarget,
            object: tab,
            userInfo: [Notification.Name.ghosttyTabDragEndedNoTargetPointKey: screenPoint])
    }
}

// MARK: Drop

/// Accepts a tab dropped onto the bar, from this window or another one.
struct TerminalTabDropDelegate: DropDelegate {
    @ObservedObject var model: TerminalTabBarViewModel
    let tabWidth: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.ghosttyTabId])
    }

    /// Which slot the cursor is over.
    private func index(at location: CGPoint) -> Int {
        guard tabWidth > 0 else { return 0 }
        return min(
            max(Int(location.x / tabWidth), 0),
            max(model.liveTabs.count - 1, 0))
    }

    func dropEntered(info: DropInfo) {
        // The dragged tab lifts in whichever bar it is over, which for a drag
        // between windows is not the one the drag started in.
        model.draggingTabID = TerminalTabDragSourceView.dragging?.id
    }

    func dropExited(info: DropInfo) {
        model.draggingTabID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Move the tab as the cursor passes over the bar, rather than only on
        // release, which is what dragging a native tab does. Animated so the
        // tabs slide past each other instead of snapping.
        if let dragging = TerminalTabDragSourceView.dragging {
            let to = index(at: info.location)
            if model.liveTabs.firstIndex(where: { $0 === dragging }) != to {
                withAnimation(.easeOut(duration: 0.15)) {
                    model.accept(dragging, at: to)
                }
            }
        }

        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard tabWidth > 0 else { return false }

        // A tab dragged within the app has already been moved by `dropUpdated`.
        if TerminalTabDragSourceView.dragging != nil { return true }

        let index = self.index(at: info.location)
        let providers = info.itemProviders(for: [.ghosttyTabId])
        guard let provider = providers.first else { return false }

        _ = provider.loadTransferable(type: TerminalTab.self) { result in
            guard case .success(let tab) = result else { return }
            DispatchQueue.main.async {
                model.accept(tab, at: index)
            }
        }

        return true
    }
}

extension Notification.Name {
    /// A tab drag ended without a drop target, so the tab becomes a window.
    static let ghosttyTabDragEndedNoTarget = Notification.Name("com.mitchellh.ghostty.tabDragEndedNoTarget")
    static let ghosttyTabDragEndedNoTargetPointKey = ghosttyTabDragEndedNoTarget.rawValue + ".point"
}
