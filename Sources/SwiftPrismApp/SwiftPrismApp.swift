import SwiftUI

@main
struct SwiftPrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bookmarks = BookmarkStore()

    init() {
        // Avoid macOS restoring a stack of stale project windows from prior debug launches.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        // Singular home / onboarding — only one of these.
        Window("Projects", id: WindowRouter.bookmarksWindowId) {
            BookmarkWindow()
                .environmentObject(bookmarks)
                .background(WindowPathMarker(isBookmarks: true))
        }
        .defaultSize(width: 520, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .codePrismOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }

        // One window per project path (stable ProjectWindowID, not raw URL).
        WindowGroup(id: WindowRouter.projectWindowId, for: ProjectWindowID.self) { $id in
            if let id {
                ProjectRootView(projectURL: id.url)
                    .environmentObject(bookmarks)
                    .background(WindowPathMarker(path: id.path))
            } else {
                Text("No project")
                    .frame(minWidth: 400, minHeight: 300)
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

extension Notification.Name {
    static let codePrismOpenProject = Notification.Name("codePrismOpenProject")
}
