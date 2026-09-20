import AppKit
import Foundation
import SwiftUI

struct ProjectBookmark: Identifiable, Codable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var lastOpened: Date
    /// Detected language ids at last open (informational).
    var languages: [String]

    var url: URL { URL(fileURLWithPath: path) }
}

/// Persisted project bookmarks (like a source-tree home window).
@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [ProjectBookmark] = []

    private let defaultsKey = "codePrism.projectBookmarks"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? decoder.decode([ProjectBookmark].self, from: data)
        else {
            bookmarks = []
            return
        }
        bookmarks = list.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func save() {
        if let data = try? encoder.encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    @discardableResult
    func remember(url: URL, languages: [String] = []) -> ProjectBookmark {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        if let idx = bookmarks.firstIndex(where: { $0.path == path }) {
            bookmarks[idx].lastOpened = Date()
            bookmarks[idx].name = name
            if !languages.isEmpty {
                bookmarks[idx].languages = languages
            }
            let item = bookmarks.remove(at: idx)
            bookmarks.insert(item, at: 0)
            save()
            return bookmarks[0]
        }
        let item = ProjectBookmark(
            path: path,
            name: name,
            lastOpened: Date(),
            languages: languages
        )
        bookmarks.insert(item, at: 0)
        save()
        return item
    }

    func remove(_ bookmark: ProjectBookmark) {
        bookmarks.removeAll { $0.path == bookmark.path }
        save()
    }

    func remove(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    func pickAndRemember() -> URL? {
        guard let url = BackendRunner.pickProjectFolder(
            start: bookmarks.first.map(\.url) ?? DemoPaths.liteTrace
        ) else { return nil }
        _ = remember(url: url)
        return url
    }
}
