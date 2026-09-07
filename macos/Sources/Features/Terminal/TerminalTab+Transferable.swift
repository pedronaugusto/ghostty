import AppKit
import CoreTransferable
import UniformTypeIdentifiers

/// Conformance to `Transferable` enables dragging a tab, including between
/// windows.
///
/// This mirrors `Ghostty.SurfaceView`'s conformance exactly: only the UUID
/// travels on the pasteboard and the receiver looks the tab back up, so nothing
/// about a live terminal has to be serialized.
extension TerminalTab: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .ghosttyTabId) { tab in
            withUnsafeBytes(of: tab.id.uuid) { Data($0) }
        } importing: { data in
            guard data.count == 16 else {
                throw TransferError.invalidData
            }

            let uuid = data.withUnsafeBytes {
                $0.load(as: UUID.self)
            }

            guard let imported = await Self.find(uuid: uuid) else {
                throw TransferError.invalidData
            }

            return imported
        }
    }

    enum TransferError: Error {
        case invalidData
    }

    /// The tab with the given ID in any window of this app.
    @MainActor
    static func find(uuid: UUID) -> TerminalTab? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if let tab = controller.tabs.first(where: { $0.id == uuid }) { return tab }
        }

        return nil
    }

}

extension UTType {
    /// A format that encodes the bare UUID only for a tab, mirroring
    /// `ghosttySurfaceId`.
    static let ghosttyTabId = UTType(exportedAs: "com.mitchellh.ghosttyTabId")
}

extension NSPasteboard.PasteboardType {
    /// Pasteboard type for dragging tab IDs.
    static let ghosttyTabId = NSPasteboard.PasteboardType(UTType.ghosttyTabId.identifier)
}
