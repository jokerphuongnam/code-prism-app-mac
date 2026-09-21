import AppKit
import Foundation
import SwiftUI

/// Stable identity for project windows (URL equality is unreliable across slash / symlink forms).
struct ProjectWindowID: Codable, Hashable, RawRepresentable {
    var path: String

    init(path: String) {
        self.path = (path as NSString).standardizingPath
    }

    init(url: URL) {
        self.path = url.standardizedFileURL.path
    }

    init?(rawValue: String) {
        self.path = (rawValue as NSString).standardizingPath
    }

    var rawValue: String { path }

    var url: URL { URL(fileURLWithPath: path) }
}

enum WindowRouter {
    static let bookmarksWindowId = "bookmarks"
    static let projectWindowId = "project"

    /// Bring the single Projects (onboarding) window forward — never spawn a second one.
    static func focusBookmarks() {
        if let win = NSApp.windows.first(where: { isBookmarksWindow($0) }) {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        // Fall back: ask SwiftUI to present the singular Window.
        NotificationCenter.default.post(name: .codePrismFocusBookmarks, object: nil)
    }

    /// Focus existing project window if open; returns false when caller should `openWindow`.
    @discardableResult
    static func focusProject(id: ProjectWindowID) -> Bool {
        if let win = NSApp.windows.first(where: { windowPath($0) == id.path }) {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    static func markWindow(_ window: NSWindow?, path: String) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(path)
    }

    static func markBookmarksWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(bookmarksWindowId)
    }

    private static func windowPath(_ window: NSWindow) -> String? {
        let id = window.identifier?.rawValue
        guard let id, id != bookmarksWindowId, id.hasPrefix("/") else { return nil }
        return (id as NSString).standardizingPath
    }

    private static func isBookmarksWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == bookmarksWindowId
            || window.title == "Projects"
            || window.title.contains("Code Prism")
    }
}

extension Notification.Name {
    static let codePrismFocusBookmarks = Notification.Name("codePrismFocusBookmarks")
}

/// Attach a stable path id to the hosting NSWindow (for focus-existing).
struct WindowPathMarker: NSViewRepresentable {
    var path: String?
    var isBookmarks: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if isBookmarks {
                WindowRouter.markBookmarksWindow(view.window)
            } else if let path {
                WindowRouter.markWindow(view.window, path: path)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if isBookmarks {
                WindowRouter.markBookmarksWindow(nsView.window)
            } else if let path {
                WindowRouter.markWindow(nsView.window, path: path)
            }
        }
    }
}
