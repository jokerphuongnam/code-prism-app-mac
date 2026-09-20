import Foundation

enum DemoPaths {
    /// Default sample project (clear View/Model graph).
    static var liteTrace: URL {
        URL(fileURLWithPath: ("~/Documents/Code/iOS/LiteTrace" as NSString).expandingTildeInPath)
    }

    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CodePrism", isDirectory: true)
    }

    static var backendsRoot: URL {
        supportRoot.appendingPathComponent("backends", isDirectory: true)
    }

    /// Sibling checkout of a `*-prism` backend repo (optional).
    static func siblingBackendRepo(_ name: String) -> URL {
        URL(fileURLWithPath: ("~/Documents/Code/\(name)" as NSString).expandingTildeInPath)
    }
}
