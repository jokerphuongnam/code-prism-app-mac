import Foundation

/// Recursive FSEvents watcher; debounced callback on source changes.
final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "app.codeprism.watcher")
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
                // Filter noisy paths inside callback
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                let interesting = paths.contains { p in
                    let lower = p.lowercased()
                    if lower.contains("/.git/") || lower.contains("/.build/") || lower.contains("/deriveddata/") {
                        return false
                    }
                    // Only care about source-like files
                    let ext = (p as NSString).pathExtension.lowercased()
                    return !ext.isEmpty
                }
                if interesting || numEvents > 0 {
                    watcher.scheduleFire()
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8,
            FSEventStreamCreateFlags(flags)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func scheduleFire() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    deinit { stop() }
}
