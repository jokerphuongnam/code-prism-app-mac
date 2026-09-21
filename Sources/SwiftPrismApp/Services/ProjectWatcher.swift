import Foundation

/// Recursive FSEvents watcher; debounced callback on **source** changes only.
final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "app.codeprism.watcher")
    /// When false, filesystem events are ignored (e.g. while Build is running).
    var isEnabled: Bool = true
    var onChange: (() -> Void)?

    func stop() {
        debounceWork?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func start(projectRoot: URL) {
        stop()
        isEnabled = true
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [projectRoot.path as CFString] as CFArray
        let flags = UInt(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, _, _) in
                guard let info else { return }
                let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
                guard watcher.isEnabled else { return }
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                let interesting = paths.contains { projectWatcherIsInterestingSourcePath($0) }
                // Only fire for real source edits — never on "any event" (that caused analyze storms).
                if interesting {
                    watcher.scheduleFire()
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,
            FSEventStreamCreateFlags(flags)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func scheduleFire() {
        guard isEnabled else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            DispatchQueue.main.async { self.onChange?() }
        }
        debounceWork = work
        // Long debounce — avoid thrashing while editors/indexers settle after Open.
        queue.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    deinit { stop() }
}

private let projectWatcherSkipParts: [String] = [
    "/.git/", "/.build/", "/deriveddata/", "/node_modules/", "/.agents/",
    "/pods/", "/.swiftpm/", "/xcuserdata/", "/build/", "/dist/", "/target/",
    "/.next/", "/vendor/", "/__pycache__/",
]

private let projectWatcherSourceExtensions: Set<String> = [
    "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cxx",
    "kt", "kts", "java", "rs", "go", "js", "jsx", "ts", "tsx",
    "marlin", "marlinheader", "py", "cs",
]

private func projectWatcherIsInterestingSourcePath(_ path: String) -> Bool {
    let lower = path.lowercased()
    if projectWatcherSkipParts.contains(where: { lower.contains($0) }) { return false }
    let ext = (path as NSString).pathExtension.lowercased()
    return projectWatcherSourceExtensions.contains(ext)
}
