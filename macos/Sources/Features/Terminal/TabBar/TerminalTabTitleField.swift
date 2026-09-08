import AppKit
import SwiftUI

/// The in-place rename editor for a tab in our own tab bar.
///
/// This is a real `NSTextField` rather than a SwiftUI `TextField`, for the same
/// reason `TabTitleEditor` uses one to rename a native tab: a SwiftUI text
/// field inside our titlebar accessory hangs the app.
///
/// When any text field becomes first responder, AppKit's autofill heuristic
/// asks it for `nextValidKeyView` to work out whether the field is part of a
/// login form. With no explicit key-view loop -- every terminal xib sets
/// `autorecalculatesKeyViewLoop="NO"` -- AppKit answers that by computing the
/// next key view *visually*, which walks the whole window and recurses into
/// every `NSHostingView` it finds, enumerating SwiftUI's focus graph. In the
/// tab bar that enumeration explodes: with the bar in the titlebar row
/// (`macos-titlebar-style = tabs`) and more than one tab, the main thread spins
/// at 100% allocating around 27MB a second and takes hours to come back.
///
/// It is the enumeration that is pathological, not anything in the bar. Every
/// piece of a tab was removed in turn -- the drag source, the close and reset
/// zoom buttons, the title, the accessibility container and its actions, the
/// tooltip -- and it hung identically each time. One tab never hangs and two
/// always do, so the cost is in how the candidates combine rather than in how
/// many there are.
///
/// So the field answers `nextValidKeyView` and `previousValidKeyView` itself
/// and that computation never runs. Nothing is lost by it: this is a lone
/// editor over a tab, with no other control to tab to, so Tab and Shift-Tab
/// commit the edit the way Return does.
struct TerminalTabTitleField: NSViewRepresentable {
    @Binding var text: String

    /// The bar's font, so the editor matches the title it replaces.
    let font: NSFont?

    /// Return, or losing focus, keeps the edit. Escape throws it away.
    ///
    /// The edited text is handed over rather than read back through the
    /// binding, so committing never depends on a state write having already
    /// propagated.
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = TabTitleField()
        field.delegate = context.coordinator

        // Same configuration `TabTitleEditor` gives the native tab's editor: no
        // chrome of its own, one clipped scrolling line.
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.alignment = .center
        if let cell = field.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.usesSingleLineMode = true
            cell.isScrollable = true
        }

        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        // Never write over what is being typed.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.font = font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalTabTitleField

        /// Set while we are tearing the editor down, so the end-of-editing
        /// notification that follows doesn't commit a second time.
        private var isFinishing = false

        init(parent: TerminalTabTitleField) {
            self.parent = parent
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertBacktab(_:)):
                // Tab and Shift-Tab commit rather than move focus. Left to
                // AppKit they would end editing with a tab movement, and the
                // field would then look for the view to move to -- the walk
                // the overrides below exist to keep from running.
                finish(control as? NSTextField, commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(control as? NSTextField, commit: false)
                return true
            default:
                return false
            }
        }

        /// Clicking away keeps the edit, which is what an `NSTextField` does
        /// everywhere else and what the native tab's editor does.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isFinishing else { return }
            finish(notification.object as? NSTextField, commit: true)
        }

        private func finish(_ field: NSTextField?, commit: Bool) {
            guard !isFinishing else { return }
            isFinishing = true
            defer { isFinishing = false }

            let edited = field?.stringValue ?? parent.text

            // Give up first responder before the field leaves the view tree, so
            // the window isn't left pointing at a field that is going away.
            if let window = field?.window, window.firstResponder !== window {
                window.makeFirstResponder(nil)
            }

            if commit {
                parent.text = edited
                parent.onCommit(edited)
            } else {
                parent.onCancel()
            }
        }
    }
}

/// The editor itself. See `TerminalTabTitleField` for why this exists.
private class TabTitleField: NSTextField {
    /// Answering these directly is the fix.
    ///
    /// AppKit would otherwise compute them by walking the window and recursing
    /// into our hosting view, which is the traversal that hangs. The autofill
    /// heuristic asks for the next one; Shift-Tab and Full Keyboard Access ask
    /// for the previous one through the same computation. There is nothing to
    /// move to from here anyway.
    override var nextValidKeyView: NSView? { nil }
    override var previousValidKeyView: NSView? { nil }

    private var hasTakenFocus = false

    /// Take first responder as soon as we are really in a window.
    ///
    /// Keyed off entering the window rather than off `updateNSView`, which is
    /// only called again if something changes: a field placed after the last
    /// update would otherwise never be focused. Letting SwiftUI deliver focus
    /// is what this whole type exists to avoid.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasTakenFocus, let window else { return }
        hasTakenFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}
