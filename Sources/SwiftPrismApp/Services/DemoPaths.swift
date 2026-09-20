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

    /// Backend checkouts live under `~/Documents/Code/code-prism/backends/<repo>`.
    static var backendsCheckoutRoot: URL {
        URL(fileURLWithPath: ("~/Documents/Code/code-prism/backends" as NSString).expandingTildeInPath)
    }

    /// Resolve a `*-prism` backend repo folder (e.g. `swift-prism`, `js-prism`).
    static func siblingBackendRepo(_ name: String) -> URL {
        backendsCheckoutRoot.appendingPathComponent(name, isDirectory: true)
    }
}
