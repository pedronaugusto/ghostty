import AppKit
import SwiftUI

private typealias Material = TerminalTabBarViewModel.Material

/// The tab bar we draw for ourselves with `macos-non-native-tabs`.
///
/// macOS redesigned the tab bar in macOS 26, so we have two variants here. It
/// is the same split `TitlebarTabsTahoeTerminalWindow` and
/// `TitlebarTabsVenturaTerminalWindow` make. On macOS 26 the bar is a rounded
/// track with the selected tab drawn as a capsule inside it. Before that, tabs
/// are full-height fills and we only paint the *unselected* ones.
///
/// No layer here is filled with a named system color. The native bar composites
/// over the titlebar rather than filling with one, which is the point
/// `TransparentTitlebarTerminalWindow.hideEffectView` makes at length. On
/// macOS 26 every background is a `TerminalTabBarViewModel.Material`; the older
/// style paints only the tabs it has to, in the window's own colors.
struct TerminalTabBarView: View {
    @ObservedObject var model: TerminalTabBarViewModel

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

    /// Width we leave on the left for the window buttons when the bar is in
    /// the titlebar. These are the insets
    /// `TitlebarTabsTahoeTerminalWindow` and `TitlebarTabsVenturaTerminalWindow`
    /// use for the native bar.
    static var windowButtonsInset: CGFloat {
        if #available(macOS 26.0, *) { return 70 }
        return 78
    }

    /// Side of the square controls in a tab (close, reset zoom), matching
    /// `NSTabBarNewTabButton`.
    fileprivate static let controlSide: CGFloat = 20

    /// Narrowest a tab may get. Past this we stop sharing the width out and
    /// scroll the track instead, which is what the native bar does.
    ///
    /// Measured off the real tab bar: it divides the track evenly down to 120
    /// points a tab and holds there, so an 880 point window starts scrolling at
    /// seven tabs (macOS 26.2, Sep 2026).
    static let minTabWidth: CGFloat = 120

    /// How wide each tab is when `count` of them share a track this wide.
    ///
    /// We share the track out evenly until a tab would go under `minTabWidth`.
    /// Past that we hold the width and let the track scroll. A nil track is one
    /// we haven't been given a width for yet.
    static func tabWidth(track: CGFloat?, count: Int) -> CGFloat {
        guard let track, track > 0 else { return minTabWidth }
        return max(minTabWidth, track / CGFloat(max(count, 1)))
    }

    /// The height of the track, which is the height of the bar and also the
    /// diameter of the round "+" button beside it.
    ///
    /// Measured off the real tab bar: its track spans 28 points, a 22 point
    /// fill between two 2 point edges. Ours lands on the same pixels
    /// (macOS 26.2, Sep 2026).
    fileprivate static let trackHeight: CGFloat = 28

    /// In its own row the track sits flush with the top and the rest of the row
    /// is below it. In the titlebar we center it on the window buttons.
    fileprivate static let rowBottomPadding: CGFloat = 8
    fileprivate static let titlebarVerticalPadding: CGFloat = 6

    /// Inset of the selected capsule, and of the hover fill, within the tab.
    fileprivate static let capsuleInset: CGFloat = 2

    /// An unselected tab lifts under the cursor. A control inside it lifts
    /// again on top of that.
    fileprivate static let hover = Material(
        dark: .init(gray: 77, opacity: 0.498),
        light: .init(gray: 183, opacity: 0.453))
    fileprivate static let controlWell = Material(
        dark: .init(gray: 99, opacity: 0.676),
        light: .init(gray: 170, opacity: 0.603))

    /// The divider between two plain tabs barely takes the background at all.
    /// It doesn't run the track's full height either.
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

    /// How far the track sits from the window's edges. Measured off the real
    /// tab bar, which starts its track 8 points in (macOS 26.2, Sep 2026).
    private static let trackInset: CGFloat = 8

    /// The gap between the track and the "+" button that sits outside it.
    private static let trackGap: CGFloat = 4

    /// AppKit already offsets a `.left` titlebar accessory past the window
    /// buttons, so the bar adds no inset of its own there.
    private static let titlebarSideInset: CGFloat = 0

    /// Room between a tab's contents and its edges. This is what keeps the
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

    /// The selected capsule with the window not key.
    ///
    /// The native bar lets the selection recede rather than dropping it: over
    /// backgrounds spanning the luminance range its fill falls from gray 105 to
    /// 80 in dark appearance and barely moves in light, and the rim follows the
    /// fill down (macOS 26.2, Sep 2026). Nothing else in the track changes.
    private static let selectedInactive = Material(
        dark: .init(gray: 80, opacity: 0.500),
        light: .init(gray: 241, opacity: 0.803))
    private static let selectedStrokeInactive = Material(
        dark: .init(gray: 180, opacity: 0.395),
        light: .init(gray: 255, opacity: 0.888))

    private static let newTabWell = Material(
        dark: .init(gray: 14, opacity: 0.327),
        light: .init(gray: 255, opacity: 0.598))
    private static let newTabWellHover = Material(
        dark: .init(gray: 65, opacity: 0.327),
        light: .init(gray: 249, opacity: 0.598))

    /// The "+" well is lit from above. Its rim is brighter at the top than at
    /// the bottom, and that is what makes it read as raised.
    private static let newTabRimTop = Material(
        dark: .init(gray: 75, opacity: 0.640),
        light: .init(gray: 255, opacity: 0.920))
    private static let newTabRimBottom = Material(
        dark: .init(gray: 46, opacity: 0.364),
        light: .init(gray: 255, opacity: 0.841))

    /// Width the tab track gets, which is what the bar has left over once the
    /// "+" button and the insets are taken out. Nil before we have been given a
    /// width, when there is nothing to divide up yet.
    private var trackWidth: CGFloat? {
        let usable = model.availableWidth
            - Self.trackInset * 2
            - TerminalTabBarView.trackHeight
            - Self.trackGap
        return usable > 0 ? usable : nil
    }

    private var tabWidth: CGFloat {
        TerminalTabBarView.tabWidth(track: trackWidth, count: model.tabs.count)
    }

    /// The capsule the selected tab is drawn in.
    private func capsule() -> some View {
        let fill = model.isKeyWindow ? Self.selected : Self.selectedInactive
        let stroke = model.isKeyWindow ? Self.selectedStroke : Self.selectedStrokeInactive
        return Capsule()
            .fill(model.fill(fill))
            .overlay(Capsule().strokeBorder(model.fill(stroke), lineWidth: 1))
            .padding(TerminalTabBarView.capsuleInset)
    }

    var body: some View {
        HStack(spacing: Self.trackGap) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                            TerminalTabBarItem(
                                tab: tab,
                                model: model,
                                isActive: index == model.activeIndex,
                                // Adjacent unselected tabs need a hairline
                                // between them. The selected capsule is its own
                                // boundary.
                                showsTrailingDivider: model.showsDivider(after: tab),
                                closeInset: Self.closeInset,
                                contentInset: Self.contentInset,
                                background: {
                                    // A press selects before it can drag, so the
                                    // tab being dragged is always the selected
                                    // one and it keeps the selection's capsule
                                    // as it slides.
                                    if index == model.activeIndex { capsule() }
                                }
                            )
                            .frame(width: tabWidth)
                            .id(tab.id)
                            .contextMenu { TerminalTabContextMenu(model: model, tab: tab) }
                        }
                    }
                }
                .onChange(of: model.activeIndex) { index in
                    // Never while a tab is being dragged. The dragged tab is
                    // the selected one, so following it would scroll the track
                    // out from under the cursor and carry the tab further than
                    // the user asked for.
                    guard model.draggingTabID == nil else { return }
                    scrollToTab(proxy, in: model.tabs, at: index)
                }
                // Narrowing the window can push the selected tab off the end
                // without its index changing, so width has to bring it back
                // too.
                .onChange(of: model.availableWidth) { _ in
                    guard model.draggingTabID == nil else { return }
                    scrollToTab(proxy, in: model.tabs, at: model.activeIndex)
                }
            }
            .frame(width: trackWidth, height: TerminalTabBarView.trackHeight)
            .background(Capsule().fill(model.fill(Self.track)))

            TerminalTabBarRoundButton(
                systemName: "plus",
                help: "New Tab",
                identifier: "_newTabButton",
                fill: model.fill(Self.newTabWell),
                hoverFill: model.fill(Self.newTabWellHover),
                // The native button loses its rim and its glyph goes to the
                // faintest label color when the window isn't key, leaving the
                // well alone.
                rim: model.isKeyWindow ? LinearGradient(
                    colors: [model.fill(Self.newTabRimTop), model.fill(Self.newTabRimBottom)],
                    startPoint: .top,
                    endPoint: .bottom) : nil,
                foreground: Color(nsColor: model.isKeyWindow ? .labelColor : .tertiaryLabelColor),
                action: model.newTab)
        }
        // We left-align with the frame rather than a trailing spacer. A spacer
        // is another child of a spaced stack, so we'd get an extra gap and
        // overflow the row.
        .frame(maxWidth: .infinity, alignment: .leading)
        // This sits outside the track so a drop past the last tab still lands
        // on us. The location it hands us is in this row's coordinates, which
        // the track starts at, and it does not move when the track scrolls, so
        // the delegate adds the scroll offset back on.
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

/// The pre-macOS-26 tab bar. Tabs are full height, we fill the *unselected*
/// ones, and we leave the selected one alone so the titlebar shows through.
/// These are the overlays `TitlebarTabsVenturaTerminalWindow` applies to the
/// real `NSTabBar`.
private struct TerminalTabBarVenturaView: View {
    @ObservedObject var model: TerminalTabBarViewModel

    /// Tabs in this style are plain fills rather than capsules, so the title
    /// and the close button use the same inset. The macOS 26 style needs two,
    /// because the capsule's rounded ends leave the title less room than the
    /// button.
    private static let itemPadding: CGFloat = 2

    /// Pre-macOS-26 the whole bar dims when the window isn't key.
    /// `TitlebarTabsVenturaTerminalWindow` uses the same value.
    private static let inactiveChromeAlpha: CGFloat = 0.5

    /// Space kept clear past the "+" button, so it doesn't sit against whatever
    /// the titlebar puts on that side.
    private static let trailingInset: CGFloat = 8

    /// Width the tabs get, which is everything the bar has apart from the "+"
    /// button and the space after it. Nil before we have been given a width.
    private var trackWidth: CGFloat? {
        let usable = model.availableWidth
            - TerminalTabBarView.controlSide
            - Self.trailingInset
        return usable > 0 ? usable : nil
    }

    private var tabWidth: CGFloat {
        TerminalTabBarView.tabWidth(track: trackWidth, count: model.tabs.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
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
                            .id(tab.id)
                            .contextMenu { TerminalTabContextMenu(model: model, tab: tab) }
                        }
                    }
                }
                .onChange(of: model.activeIndex) { index in
                    // Never while a tab is being dragged. The dragged tab is
                    // the selected one, so following it would scroll the track
                    // out from under the cursor and carry the tab further than
                    // the user asked for.
                    guard model.draggingTabID == nil else { return }
                    scrollToTab(proxy, in: model.tabs, at: index)
                }
                // Narrowing the window can push the selected tab off the end
                // without its index changing, so width has to bring it back
                // too.
                .onChange(of: model.availableWidth) { _ in
                    guard model.draggingTabID == nil else { return }
                    scrollToTab(proxy, in: model.tabs, at: model.activeIndex)
                }
            }
            .frame(width: trackWidth, height: TerminalTabBarView.trackHeight)

            TerminalTabBarSquareButton(
                systemName: "plus",
                help: "New Tab",
                identifier: "_newTabButton",
                hoverFill: model.fill(TerminalTabBarView.controlWell),
                action: model.newTab)

            Spacer(minLength: 0)
        }
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
            // Very dark themes are the one case where we paint the selected
            // tab. "Nothing" and "the titlebar" look identical there.
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

/// Bring the selected tab into view.
///
/// Once tabs stop shrinking we scroll the track instead, so the tab we just
/// selected can be off the end of it.
private func scrollToTab(_ proxy: ScrollViewProxy, in tabs: [TerminalTab], at index: Int) {
    guard tabs.indices.contains(index) else { return }

    // No anchor, so a tab that is already on screen stays where it is. An
    // anchor recenters it, which moves the track under a press that has not
    // become a drag yet and throws the first reorder off.
    proxy.scrollTo(tabs[index].id)
}

// MARK: Tab

/// One tab.
///
/// The contents and their spacing match the accessory view
/// `TerminalWindow.awakeFromNib` hands a native tab, so a tab reads the same
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

    /// In-place rename. With native tabs `TabTitleEditor` does this to
    /// AppKit's own tab view. Here the field is just part of the tab.
    @State private var isRenaming: Bool = false
    @State private var draftTitle: String = ""
    @FocusState private var renameFocused: Bool

    /// A tab being dragged is already lifted, so we give it neither the hover
    /// highlight nor the close button on top of that.
    private var isDragging: Bool {
        tab.id == model.draggingTabID
    }

    private var isHovering: Bool {
        model.hoveredTabID == tab.id
    }

    /// Only the selected tab's label is at full strength. None of them are
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

            // The title is centered with the controls floating over its ends.
            // That is how AppKit lays out a tab.
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

            // Above the decoration so a press anywhere on the tab starts a
            // drag. Below the controls and the rename field so those keep their
            // own clicks.
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
                        // We hide it rather than remove it so titles never shift.
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
        // Selecting a tab happens in `TerminalTabDragSourceView.mouseDown`, which
        // VoiceOver never reaches, so activating the element has to do it too.
        .accessibilityAction { model.select(tab) }
        .accessibilityAction(named: "Close Tab") { model.close(tab) }
        .accessibilityAction(named: "Move Tab to New Window") { model.moveToNewWindow(tab) }
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
        model.setTitleOverride(draftTitle, for: tab)
    }
}

// MARK: Controls

/// A borderless square control sized like `NSTabBarNewTabButton`.
///
/// We set identifiers so UI tests can find these the way
/// `GhosttyTitlebarTabsUITests` finds AppKit's own `_closeButton`. SwiftUI
/// can't publish an `NSAccessibility` tab role, so our contract here is
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
    let rim: LinearGradient?
    let foreground: Color
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
                .overlay { if let rim { Circle().strokeBorder(rim, lineWidth: 1) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}
