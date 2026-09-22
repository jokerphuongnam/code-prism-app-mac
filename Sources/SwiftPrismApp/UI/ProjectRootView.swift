import AppKit
import SwiftUI

/// One window = one project (own GraphAppModel). Re-opening the same path focuses this window.
struct ProjectRootView: View {
    let projectURL: URL
    @EnvironmentObject private var bookmarks: BookmarkStore
    @StateObject private var model = GraphAppModel()

    private var standardizedURL: URL {
        URL(fileURLWithPath: projectURL.standardizedFileURL.path)
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(bookmarks)
            .frame(minWidth: 1100, minHeight: 700)
            .navigationTitle(standardizedURL.lastPathComponent)
            .background(WindowPathMarker(path: standardizedURL.path))
            .onAppear {
                model.attachBookmarks(bookmarks)
                let path = standardizedURL.path
                if model.projectRoot?.standardizedFileURL.path != path {
                    model.adoptProject(standardizedURL)
                }
                // Focus this project window only — do not close siblings (avoids SIGTERM under Xcode).
                DispatchQueue.main.async {
                    _ = WindowRouter.focusProject(id: ProjectWindowID(path: path))
                }
            }
    }
}
