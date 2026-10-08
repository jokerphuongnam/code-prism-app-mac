import AppKit

/// Keep the process alive when windows are collapsed/reordered.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Project the link asked to open before the home window exists.
    static var pendingProject: URL?
    /// User chose Home. Do not dismiss that window when a link arrives.
    static var userOpenedHome = false
    /// This launch was a project link, so the automatic dashboard is not wanted.
    static var openedFromLink = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let root = PrismIncomingLink.projectRoot(from: url) else { continue }
            Self.pendingProject = root
            Self.openedFromLink = true
            NotificationCenter.default.post(name: .codePrismOpenLinkedProject, object: root)
        }
    }
}

enum PrismIncomingLink {
    static func projectRoot(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "codeprism" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        guard let path = items?.first(where: { $0.name == "root" })?.value, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

extension Notification.Name {
    static let codePrismOpenLinkedProject = Notification.Name("codePrismOpenLinkedProject")
}
