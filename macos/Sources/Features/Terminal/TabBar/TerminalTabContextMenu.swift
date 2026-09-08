import SwiftUI

/// The right-click menu on a tab in Ghostty's own tab bar.
///
/// With native tabs this menu is built by AppKit for `NSTabBar` and Ghostty
/// only adds to it (see `TerminalWindow.configureTabContextMenuIfNeeded`).
/// There is no `NSTabBar` when we draw the tabs ourselves, so the commands are
/// rebuilt here, in the order AppKit puts them in.
///
/// Two differences. Tab color is a submenu: the native menu embeds
/// `TabColorMenuView` as a custom `NSMenuItem` view, which a SwiftUI
/// `contextMenu` can't host. And there is no "Show All Tabs", which is
/// AppKit's tab overview and has nothing behind it here.
struct TerminalTabContextMenu: View {
    @ObservedObject var model: TerminalTabBarViewModel
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Button("Close Tab") { model.close(tab) }

        if model.tabs.count > 1 {
            Button("Close Other Tabs") { model.closeOthers(tab) }
        }

        if model.hasTabsToTheRight(tab) {
            Button("Close Tabs to the Right") { model.closeToTheRight(tab) }
        }

        if model.tabs.count > 1 {
            Divider()
            Button("Move Tab to New Window") { model.moveToNewWindow(tab) }
        }

        Divider()

        Button("Rename Tab...") { model.rename(tab) }

        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    model.setColor(color, for: tab)
                } label: {
                    if color == tab.tabColor {
                        Label(color.localizedName, systemImage: "checkmark")
                    } else {
                        Text(color.localizedName)
                    }
                }
            }
        }
    }
}
