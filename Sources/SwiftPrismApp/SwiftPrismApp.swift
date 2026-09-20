import SwiftUI

@main
struct SwiftPrismApp: App {
    @StateObject private var bookmarks = BookmarkStore()

    var body: some Scene {
        // Home: bookmark / source-tree window
        Window("Projects", id: "bookmarks") {
            BookmarkWindow()
                .environmentObject(bookmarks)
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

        // One window per project
        WindowGroup("Project", id: "project", for: URL.self) { $url in
            if let url {
                ProjectRootView(projectURL: url)
                    .environmentObject(bookmarks)
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
