import Foundation

/// Watches a directory for content changes via a `DispatchSource` file-system-object source
/// (Issue #17, Phase 2). Coalesces bursts of events with a debounce so a batch of files
/// landing at once triggers a single callback. The `onChange` closure is called on the main
/// queue. `stop()` (or deinit) tears down the source and closes the fd.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32
    private var debounce: DispatchWorkItem?
    private let debounceSeconds: Double
    private let onChange: () -> Void

    init?(url: URL, debounceSeconds: Double = 8, onChange: @escaping () -> Void) {
        let handle = open(url.path, O_EVTONLY)
        guard handle >= 0 else { return nil }
        self.fd = handle
        self.debounceSeconds = debounceSeconds
        self.onChange = onChange
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle, eventMask: [.write, .rename, .delete], queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(handle) }
        source.resume()
    }

    private func schedule() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceSeconds, execute: work)
        }
    }

    func stop() {
        debounce?.cancel()
        source.cancel()
    }

    deinit { source.cancel() }
}
