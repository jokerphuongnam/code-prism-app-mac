import SwiftUI

/// Home window: bookmark / source-tree list. Opening a project spawns another window.
struct BookmarkWindow: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                if bookmarks.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No bookmarked projects",
                        systemImage: "folder.badge.plus",
                        description: Text("File → Open… or click Open Project to choose a folder. It will be saved here.")
                    )
                } else {
                    List {
                        ForEach(bookmarks.bookmarks) { item in
                            BookmarkRow(item: item) {
                                openProject(item.url)
                            }
                            .contextMenu {
                                Button("Open") { openProject(item.url) }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                Divider()
                                Button("Remove Bookmark", role: .destructive) {
                                    bookmarks.remove(item)
                                }
                            }
                        }
                        .onDelete(perform: bookmarks.remove)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        if let url = bookmarks.pickAndRemember() {
                            openProject(url)
                        }
                    } label: {
                        Label("Open Project…", systemImage: "folder")
                    }
                    .keyboardShortcut("o", modifiers: [.command])

                    Button {
                        let url = DemoPaths.liteTrace
                        guard FileManager.default.fileExists(atPath: url.path) else { return }
                        _ = bookmarks.remember(url: url, languages: ["swift"])
                        openProject(url)
                    } label: {
                        Text("LiteTrace")
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .codePrismOpenProject)) { _ in
            if let url = bookmarks.pickAndRemember() {
                openProject(url)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Code Prism")
                    .font(.headline)
                Text("Bookmarks — open a project in a new window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private func openProject(_ url: URL) {
        _ = bookmarks.remember(url: url)
        openWindow(id: "project", value: url)
    }
}

private struct BookmarkRow: View {
    let item: ProjectBookmark
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !item.languages.isEmpty {
                        Text(item.languages.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(item.lastOpened, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import AppKit
