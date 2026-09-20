import SwiftUI

/// One window = one project (own GraphAppModel).
struct ProjectRootView: View {
    let projectURL: URL
    @EnvironmentObject private var bookmarks: BookmarkStore
    @StateObject private var model = GraphAppModel()

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(bookmarks)
            .frame(minWidth: 1100, minHeight: 700)
            .navigationTitle(projectURL.lastPathComponent)
            .onAppear {
                model.attachBookmarks(bookmarks)
                if model.projectRoot != projectURL {
                    model.adoptProject(projectURL)
                }
            }
    }
}
