import AppKit
import SwiftUI

private typealias Material = TerminalTabBarViewModel.Material

/// The tab bar Ghostty draws for itself with `macos-non-native-tabs`.
///
/// macOS redesigned the tab bar in macOS 26, so there are two variants here for
/// the same reason `TitlebarTabsTahoeTerminalWindow` and
/// `TitlebarTabsVenturaTerminalWindow` are separate types. On macOS 26 the bar
/// is a rounded track with the selected tab drawn as a capsule inside it; on
/// earlier versions tabs are full-height fills and only the *unselected* ones
/// are painted.
///
/// Nothing here uses a named system color. Native tabs are a compositing effect
/// over the titlebar rather than a fill, which is the point made at length in
/// `TransparentTitlebarTerminalWindow.hideEffectView`, so every layer is a
/// `TerminalTabBarViewModel.Material` instead.
struct TerminalTabBarView: View {
    @ObservedObject var model: TerminalTabBarViewModel

    /// Coordinate space the bar publishes so a tab drag can be measured against
    /// the bar rather than against the tab, which moves as it reorders.
    static let coordinateSpace = "com.mitchellh.ghostty.tabBar"

    /// Height of the row the bar occupies when it has its own row below the
    /// titlebar, which is where macOS puts it.
    static var rowHeight: CGFloat {
        if #available(macOS 26.0, *) { return trackHeight + rowBottomPadding }
        return trackHeight
    }

    /// Height of the bar when it lives in the titlebar itself, i.e. with
    /// `macos-titlebar-style = tabs`.
    static var titlebarHeight: CGFloat {
        if #available(macOS 26.0, *) { return trackHeight + titlebarVerticalPadding * 2 }
        return trackHeight
    }

    /// Width reserved to the left of the bar for the window buttons when the
    /// bar is in the titlebar. These are the insets
    /// `TitlebarTabsTahoeTerminalWindow` and `TitlebarTabsVenturaTerminalWindow`
    /// use for the native bar.
    static var windowButtonsInset: CGFloat {
        if #available(macOS 26.0, *) { return 70 }
        return 78
    }

    /// Side of the square controls in a tab (close, reset zoom), matching
    /// `NSTabBarNewTabButton`.
    fileprivate static let controlSide: CGFloat = 20

    /// Narrowest a tab may shrink to. Past this the native bar scrolls its
    /// tabs and we clip instead.
    fileprivate static let minTabWidth: CGFloat = 64

    fileprivate static let trackHeight: CGFloat = 28

    /// In its own row the track sits flush with the top and the rest of the row
    /// is below it; in the titlebar it is centered on the window buttons.
    fileprivate static let rowBottomPadding: CGFloat = 8
    fileprivate static let titlebarVerticalPadding: CGFloat = 6

    /// Inset of the selected capsule, and of the hover fill, within the tab.
    fileprivate static let capsuleInset: CGFloat = 2

    /// An unselected tab lifts under the cursor, and a control within it lifts
    /// again on top of that.
    fileprivate static let hover = Material(
        dark: .init(gray: 77, opacity: 0.498),
        light: .init(gray: 183, opacity: 0.453))
    fileprivate static let controlWell = Material(
        dark: .init(gray: 99, opacity: 0.676),
        light: .init(gray: 170, opacity: 0.603))

    /// The divider between two plain tabs barely takes the background at all,
    /// and does not run the track's full height.
    fileprivate static let divider = Material(
        dark: .init(gray: 37, opacity: 0.946),
        light: .init(gray: 231, opacity: 0.963))
    fileprivate static let dividerInsetY: CGFloat = 5

    var body: some View {
        if #available(macOS 26.0, *) {
            TerminalTabBarTahoeView(model: model)
        } else {
            TerminalTabBarVenturaView(model: model)
        }
    }
}

// MARK: macOS 26

/// The macOS 26 tab bar: a rounded track holding the tabs, the selected one
/// drawn as a stroked capsule, and a round "+" button outside the track.
private struct TerminalTabBarTahoeView: View {
    @ObservedObject var model: TerminalTabBarViewModel

    private static let trackInset: CGFloat = 8
    private static let trackGap: CGFloat = 4

    /// AppKit already offsets a `.left` titlebar accessory past the window
    /// buttons, so the bar adds no inset of its own there.
    private static let titlebarSideInset: CGFloat = 0

    /// Room between a tab's contents and its edges, which is what keeps the
    /// title and the shortcut off the selected capsule's rounded ends.
    private static let contentInset: CGFloat = 10

    /// The close button sits nearer the tab's edge than the title does.
    private static let closeInset: CGFloat = 5

    private static let track = Material(
        dark: .init(gray: 58, opacity: 0.476),
        light: .init(gray: 199, opacity: 0.466))
    private static let selected = Material(
        dark: .init(gray: 105, opacity: 0.571),
        light: .init(gray: 247, opacity: 0.798))
    private static let selectedStroke = Material(
        dark: .init(gray: 206, opacity: 0.452),
        light: .init(gray: 255, opacity: 0.888))

    private static let newTabWell = Material(
        dark: .init(gray: 14, opacity: 0.327),
        light: .init(gray: 255, opacity: 0.598))
    private static let newTabWellHover = Material(
        dark: .init(gray: 65, opacity: 0.327),
        light: .init(gray: 249, opacity: 0.598))

    /// The "+" well is lit from above: its rim is brighter at the top than at
    /// the bottom, which is what makes it read as raised.
    private static let newTabRimTop = Material(
        dark: .init(gray: 75, opacity: 0.640),
        light: .init(gray: 255, opacity: 0.920))
    private static let newTabRimBottom = Material(
        dark: .init(gray: 46, opacity: 0.364),
        light: .init(gray: 255, opacity: 0.841))

    private var tabWidth: CGFloat {
        let count = max(model.tabs.count, 1)
        let usable = model.availableWidth
            - Self.trackInset * 2
            - TerminalTabBarView.trackHeight
            - Self.trackGap
        guard usable > 0 else { return TerminalTabBarView.minTabWidth }
        return max(TerminalTabBarView.minTabWidth, usable / CGFloat(count))
    }

    /// The capsule the selected tab is drawn in.
    private func capsule() -> some View {
        Capsule()
            .fill(model.fill(Self.selected))
            .overlay(Capsule().strokeBorder(model.fill(Self.selectedStroke), lineWidth: 1))
            .padding(TerminalTabBarView.capsuleInset)
    }

    var body: some View {
        HStack(spacing: Self.trackGap) {
            HStack(spacing: 0) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    TerminalTabBarItem(
                        tab: tab,
                        model: model,
                        isActive: index == model.activeIndex,
                        // Adjacent unselected tabs need a hairline between
                        // them. The selected capsule is its own boundary.
                        showsTrailingDivider: model.showsDivider(after: tab),
                        closeInset: Self.closeInset,
                        contentInset: Self.contentInset,
                        background: {
                            // A press selects before it can drag, so the tab
                            // being dragged is always the selected one and it
                            // keeps the selection's capsule as it slides.
                            if index == model.activeIndex { capsule() }
                        }
                    )
                    .frame(width: tabWidth)
                    .contextMenu { TerminalTabContextMenu(model: model, tab: tab) }
                }
            }
            .frame(height: TerminalTabBarView.trackHeight)
            .background(Capsule().fill(model.fill(Self.track)))

            TerminalTabBarRoundButton(
                systemName: "plus",
                help: "New Tab",
                identifier: "_newTabButton",
                fill: model.fill(Self.newTabWell),
                hoverFill: model.fill(Self.newTabWellHover),
                rim: LinearGradient(
                    colors: [model.fill(Self.newTabRimTop), model.fill(Self.newTabRimBottom)],
                    startPoint: .top,
                    endPoint: .bottom),
                action: model.newTab)
        }
        // Left-aligned by the frame rather than a trailing spacer: a spacer is
        // another child of a spaced stack, and the extra gap overflows the row.
        .frame(maxWidth: .infinity, alignment: .leading)
        // The drop location is measured in this space, so the horizontal inset
        // has to be inside it or every index is off by that much.
        .coordinateSpace(name: TerminalTabBarView.coordinateSpace)
        .onDrop(
            of: [.ghosttyTabId],
            delegate: TerminalTabDropDelegate(model: model, tabWidth: tabWidth))
        .padding(.horizontal, model.inTitlebar ? Self.titlebarSideInset : Self.trackInset)
        .padding(.top, model.inTitlebar ? TerminalTabBarView.titlebarVerticalPadding : 0)
        .padding(.bottom, model.inTitlebar
            ? TerminalTabBarView.titlebarVerticalPadding
            : TerminalTabBarView.rowBottomPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityIdentifier("_ghosttyTabBar")
    }
}

// MARK: macOS 13 to 15

/// The pre-macOS-26 tab bar: full-height tabs where the *unselected* ones carry
/// a fill and the selected one is left alone so the titlebar shows through.
/// The overlays are the ones `TitlebarTabsVenturaTerminalWindow` applies to the
/// real `NSTabBar`.
private struct TerminalTabBarVenturaView: View {
    @ObservedObject var model: TerminalTabBarViewModel

    private static let itemPadding: CGFloat = 2

    /// Pre-macOS-26 the whole bar dims when the window isn't key.
    /// `TitlebarTabsVenturaTerminalWindow` uses the same value.
    private static let inactiveChromeAlpha: CGFloat = 0.5

    private var tabWidth: CGFloat {
        let count = max(model.tabs.count, 1)
        let usable = model.availableWidth - TerminalTabBarView.controlSide - 8
        guard usable > 0 else { return TerminalTabBarView.minTabWidth }
        return max(TerminalTabBarView.minTabWidth, usable / CGFloat(count))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                TerminalTabBarItem(
                    tab: tab,
                    model: model,
                    isActive: index == model.activeIndex,
                    showsTrailingDivider: model.showsDivider(after: tab),
                    closeInset: Self.itemPadding,
                    contentInset: Self.itemPadding,
                    background: { fill(index: index) }
                )
                .frame(width: tabWidth)
                .contextMenu { TerminalTabContextMenu(model: model, tab: tab) }
            }

            TerminalTabBarSquareButton(
                systemName: "plus",
                help: "New Tab",
                identifier: "_newTabButton",
                hoverFill: model.fill(TerminalTabBarView.controlWell),
                action: model.newTab)

            Spacer(minLength: 0)
        }
        .coordinateSpace(name: TerminalTabBarView.coordinateSpace)
        .onDrop(
            of: [.ghosttyTabId],
            delegate: TerminalTabDropDelegate(model: model, tabWidth: tabWidth))
        .opacity(model.isKeyWindow ? 1 : Self.inactiveChromeAlpha)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityIdentifier("_ghosttyTabBar")
    }

    @ViewBuilder
    private func fill(index: Int) -> some View {
        if index == model.activeIndex {
            // Very dark themes are the one case where the selected tab is
            // painted, because "nothing" and "the titlebar" look identical.
            if model.hasVeryDarkBackground {
                Color(nsColor: model.backgroundColor)
            }
        } else if model.isLightBackground {
            Color(nsColor: NSColor(genericGamma22White: 0.95, alpha: 1))
        } else {
            Color(nsColor: NSColor(genericGamma22White: 0.0, alpha: 0.45))
        }
    }
}

// MARK: Tab

/// One tab. The contents and their spacing match the accessory view
/// `TerminalWindow.awakeFromNib` hands to a native tab, so a tab reads the same
/// whichever style is in use: color dot, title, shortcut, reset zoom.
private struct TerminalTabBarItem<Background: View>: View {
    @ObservedObject var tab: TerminalTab
    @ObservedObject var model: TerminalTabBarViewModel

    let isActive: Bool
    let showsTrailingDivider: Bool

    /// Room before the close button, which sits nearer the tab's edge than
    /// anything else does.
    let closeInset: CGFloat

    /// Room around the title and after the trailing controls.
    let contentInset: CGFloat

    @ViewBuilder let background: () -> Background

    /// In-place rename, which with native tabs is what `TabTitleEditor` does
    /// to AppKit's own tab view. Here the field is just part of the tab.
    @State private var isRenaming: Bool = false
    @State private var draftTitle: String = ""
    @FocusState private var renameFocused: Bool

    /// A tab being dragged is already lifted, so it takes neither the hover
    /// highlight nor the close button on top of that.
    private var isDragging: Bool {
        tab.id == model.draggingTabID
    }

    private var isHovering: Bool {
        model.hoveredTabID == tab.id
    }

    /// Only the selected tab's label is at full strength, and none of them are
    /// when the window isn't key.
    private var titleColor: Color {
        Color(nsColor: isActive && model.isKeyWindow ? .labelColor : .secondaryLabelColor)
    }

    var body: some View {
        ZStack {
            background()

            if isHovering && !isActive && !isDragging {
                Capsule()
                    .fill(model.fill(TerminalTabBarView.hover))
                    .padding(TerminalTabBarView.capsuleInset)
            }

            // The title is centered in the tab with the controls floating over
            // its ends, which is how AppKit lays out a tab.
            Text(tab.title)
                .font(model.font)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, contentInset + TerminalTabBarView.controlSide + 4)
                .opacity(isRenaming ? 0 : 1)

            if showsTrailingDivider {
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(model.fill(TerminalTabBarView.divider))
                        .frame(width: 1)
                        .padding(.vertical, TerminalTabBarView.dividerInsetY)
                }
            }

            // Above the decoration so a press anywhere on it starts a drag, and
            // below the controls and the rename field so those keep their own
            // clicks.
            TerminalTabDragSource(tab: tab, model: model, onDoubleClick: beginRename)

            HStack(spacing: 0) {
                if isHovering && !isDragging {
                    TerminalTabBarSquareButton(
                        systemName: "xmark",
                        help: "Close Tab",
                        identifier: "_closeButton",
                        hoverFill: model.fill(TerminalTabBarView.controlWell),
                        action: { model.close(tab) })
                } else {
                    Spacer().frame(width: TerminalTabBarView.controlSide)
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Circle()
                        .fill(tab.tabColor.displayColor.map { Color(nsColor: $0) } ?? .clear)
                        .frame(width: 6, height: 6)
                        // Hidden rather than removed so titles never shift.
                        .opacity(tab.tabColor.displayColor == nil ? 0 : 1)
                        .accessibilityHidden(true)

                    if tab.bell {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(titleColor)
                            .accessibilityLabel("Bell")
                    }

                    if let shortcut = model.shortcut(for: tab) {
                        // The trailing space is padding, exactly as
                        // `TerminalWindow.keyEquivalent` writes it into the
                        // native tab's accessory label.
                        Text("\(shortcut) ")
                            .font(.system(size: NSFont.smallSystemFontSize))
                            .foregroundStyle(titleColor)
                            .accessibilityHidden(true)
                    }

                    if tab.isZoomed {
                        TerminalTabBarSquareButton(
                            systemName: "arrow.down.right.and.arrow.up.left",
                            help: "Reset Zoom",
                            identifier: "_resetZoomButton",
                            hoverFill: model.fill(TerminalTabBarView.controlWell),
                            action: { model.resetZoom(tab) })
                    }
                }
                .padding(.trailing, contentInset)
            }
            .padding(.leading, closeInset)

            if isRenaming {
                TextField("", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(model.font)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: renameFocused) { focused in
                        if !focused { commitRename() }
                    }
                    .padding(.horizontal, contentInset + 4)
            }
        }
        .help(tab.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("_ghosttyTab")
        .accessibilityAction(named: "Close Tab") { model.close(tab) }
    }

    private func beginRename() {
        model.select(tab)
        draftTitle = tab.titleOverride ?? tab.title
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        model.setTitleOverride(tab, draftTitle)
    }
}

// MARK: Controls

/// A borderless square control sized like `NSTabBarNewTabButton`.
///
/// Identifiers are set so UI tests can find these the way
/// `GhosttyTitlebarTabsUITests` finds AppKit's own `_closeButton`. SwiftUI
/// can't publish an `NSAccessibility` tab role, so our bar's contract is
/// identifier-based rather than role-based.
private struct TerminalTabBarSquareButton: View {
    let systemName: String
    let help: String
    let identifier: String
    let hoverFill: Color
    let action: () -> Void

    /// The well the cursor lights up is a little smaller than the control.
    private static let wellSide: CGFloat = 15

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .frame(
                    width: TerminalTabBarView.controlSide,
                    height: TerminalTabBarView.controlSide)
                .background(
                    Circle()
                        .fill(hoverFill)
                        .frame(width: Self.wellSide, height: Self.wellSide)
                        .opacity(isHovering ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The glyph comes up to full strength with the well under it.
        .foregroundStyle(Color(nsColor: isHovering ? .labelColor : .secondaryLabelColor))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}

/// The round button macOS 26 uses beside the tab track.
private struct TerminalTabBarRoundButton: View {
    let systemName: String
    let help: String
    let identifier: String
    let fill: Color
    let hoverFill: Color
    let rim: LinearGradient
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(
                    width: TerminalTabBarView.trackHeight,
                    height: TerminalTabBarView.trackHeight)
                .background(Circle().fill(isHovering ? hoverFill : fill))
                .overlay(Circle().strokeBorder(rim, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Unlike the controls inside a tab, this one is at full strength.
        .foregroundStyle(Color(nsColor: .labelColor))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}
