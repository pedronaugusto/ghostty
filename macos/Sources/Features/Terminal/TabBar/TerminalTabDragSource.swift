import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag source for a tab in our tab bar.
///
/// This is the tab-level counterpart to `Ghostty.SurfaceDragSource` and works
/// the same way. An AppKit view begins an `NSDraggingSession` carrying the
/// tab's UUID, so we can resolve a drop in any window rather than only the one
/// the drag started in. Going through the pasteboard rather than a SwiftUI
/// gesture also gives us an image under the cursor, which is what the native
/// tab bar does.
struct TerminalTabDragSource: NSViewRepresentable {
    let tab: TerminalTab

    /// We report hover from here rather than from SwiftUI's `.onHover`. This
    /// view sits over the tab and would otherwise swallow it.
    ///
    /// It lives on the model rather than in each tab so exactly one tab is ever
    /// hovered. Live reordering moves these views around under the cursor and
    /// enter/exit don't always arrive in pairs. With per-tab state that leaves
    /// highlights stuck on.
    @ObservedObject var model: TerminalTabBarViewModel

    /// Double-click renames in place. The press lands here rather than on the
    /// SwiftUI tab, so we have to report the gesture back out.
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
        // A drag suppresses hover. Nothing is hovered when it ends until the
        // cursor moves again.
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
    /// A drop target needs this to reorder live as the cursor moves. We can
    /// only read the pasteboard payload asynchronously, and that is far too
    /// late to move anything under the cursor. Weak because the tab is owned by
    /// whichever controller holds it, and that changes mid-drag.
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

    /// Whether the drag is over the bar, so we swap the image only when that
    /// changes rather than on every mouse move.
    private var dragWasInBar: Bool?

    /// Local event monitor to detect escape key presses during drag.
    private var escapeMonitor: Any?

    /// Whether the current drag was cancelled by pressing escape.
    private var dragCancelledByEscape: Bool = false

    /// Where the tab was when the drag started, so escape can put it back. The
    /// live reorder has already committed by then, though only ever within the
    /// window the drag started in.
    private weak var dragOriginController: TerminalController?
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
        // We select on the press rather than the release, which is what the
        // native bar does. It also makes the dragged tab always be the selected
        // one. Consuming the event stops the titlebar dragging the window.
        mouseDownLocation = event.locationInWindow
        guard let tab, let controller = TerminalController.controller(owning: tab) else { return }
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
        // draws itself lifted, the way the native bar does, so we show nothing
        // under the cursor. `movedTo` swaps the snapshot in once the drag leaves
        // the bar and the tab is really coming out.
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
        dragOriginController = TerminalController.controller(owning: tab)
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

    /// The view that actually draws the bar. This view is transparent and sits
    /// over it, so the bar is both where our pixels come from and the rect a
    /// drag has to leave before the tab appears under the cursor.
    private var barHost: NSView? {
        var host: NSView? = superview
        while let current = host, !(current is NonDraggableHostingView<TerminalTabBarView>) {
            host = current.superview
        }
        return host
    }

    /// A bitmap of the tab as it is currently drawn.
    private func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let host = barHost else { return nil }

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
        // We show the tab under the cursor only once it has left the bar. An
        // in-bar reorder should look like the tab sliding, not like a copy of
        // it floating over the window.
        guard let window else { return }

        // Containment in the bar's own rect, not just its height: dragging
        // sideways past the window edge, or up above the bar, leaves the bar as
        // much as dragging down into the terminal does, and the tab has to
        // appear under the cursor there too. Height alone kept the 1x1
        // placeholder and the drag looked like it had lost the tab.
        let point = window
            .convertFromScreen(NSRect(origin: screenPoint, size: .zero))
            .origin
        let inBar = if let bar = barHost {
            bar.convert(bar.bounds, to: nil).contains(point)
        } else {
            point.y >= window.contentLayoutRect.maxY
        }
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

        // Dropped on nothing. We give the tab a window of its own where it
        // landed, which is what dragging a native tab out does. Same rule as
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

    /// Where the cursor is against the tabs, rather than against the track they
    /// sit in. The two are the same until the track scrolls.
    private func trackX(_ location: CGPoint) -> CGFloat {
        location.x + model.trackScrollX
    }

    /// Where a tab we already own lands when the drag ends at `x`.
    ///
    /// A reorder picks an existing tab to take the place of, so it stops at the
    /// last one.
    static func reorderIndex(at x: CGFloat, tabWidth: CGFloat, count: Int) -> Int {
        guard tabWidth > 0 else { return 0 }
        return min(max(Int(x / tabWidth), 0), max(count - 1, 0))
    }

    /// Where a tab from another window is inserted when it is dropped at `x`.
    ///
    /// We have one more position here than a reorder does. An arriving tab can
    /// go after all of them, and which side of a tab's midpoint the cursor is
    /// on decides whether it does, the way an insertion point works anywhere
    /// else. Once the track scrolls there is no empty space past the last tab
    /// to drop in, so this is the only thing that can still reach the end.
    static func insertionIndex(at x: CGFloat, tabWidth: CGFloat, count: Int) -> Int {
        guard tabWidth > 0 else { return 0 }
        return min(max(Int((x + tabWidth / 2) / tabWidth), 0), count)
    }

    func dropEntered(info: DropInfo) {
        // The dragged tab lifts in whichever bar it is over. For a drag between
        // windows that is not the bar it started in.
        model.draggingTabID = TerminalTabDragSourceView.dragging?.id
    }

    func dropExited(info: DropInfo) {
        model.stopEdgeScroll()
        model.draggingTabID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // At either end of an overflowing track we keep scrolling, so every
        // position stays reachable in one drag. This runs for a tab from
        // another window too: that tab isn't ours to move yet, but the track it
        // is being dropped into still has to come to meet it.
        //
        // The closure deliberately reaches nothing but its arguments and a weak
        // model. See `edgeScroll(at:onScroll:)`.
        let tabWidth = self.tabWidth
        model.edgeScroll(at: info.location) { [weak model] location in
            guard let model,
                  let dragging = TerminalTabDragSourceView.dragging,
                  TerminalController.controller(owning: dragging) === model.controller else { return }
            Self.reorder(dragging, at: location, tabWidth: tabWidth, in: model)
        }

        // Native tabs reorder live within their window, so we do too. We keep
        // a cross-window move provisional until the drop, so Escape can't close
        // the source window.
        guard let dragging = TerminalTabDragSourceView.dragging,
              TerminalController.controller(owning: dragging) === model.controller else {
            return DropProposal(operation: .move)
        }

        Self.reorder(dragging, at: info.location, tabWidth: tabWidth, in: model)
        return DropProposal(operation: .move)
    }

    /// Move a tab the model already owns to wherever the cursor is.
    ///
    /// Static because the edge-scroll timer calls it, and a method on this
    /// struct would carry the model into the timer with it.
    private static func reorder(
        _ dragging: TerminalTab,
        at location: CGPoint,
        tabWidth: CGFloat,
        in model: TerminalTabBarViewModel
    ) {
        let to = reorderIndex(
            at: location.x + model.trackScrollX,
            tabWidth: tabWidth,
            count: model.liveTabs.count)
        guard model.liveTabs.firstIndex(where: { $0 === dragging }) != to else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            model.accept(dragging, at: to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // `dropExited` is what normally takes the bar out of drag mode, and it
        // does not fire on a drop we accepted. Leaving it set keeps the moved
        // tab's close button suppressed and stops selection scrolling.
        defer {
            model.stopEdgeScroll()
            model.draggingTabID = nil
        }
        guard tabWidth > 0 else { return false }

        if let dragging = TerminalTabDragSourceView.dragging {
            if TerminalController.controller(owning: dragging) !== model.controller {
                model.accept(dragging, at: Self.insertionIndex(
                    at: trackX(info.location), tabWidth: tabWidth, count: model.liveTabs.count))
            }
            return true
        }

        let index = Self.insertionIndex(
            at: trackX(info.location), tabWidth: tabWidth, count: model.liveTabs.count)
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
