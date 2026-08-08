import Combine
import Foundation

/// Tails provider stdout/stderr and watchdog logs with separate source buffers.
@MainActor
final class ProviderLogTail: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var watchdogLines: [String] = []

    private let capacity: Int
    private var stderrReader: LogTailReader?
    private var stdoutReader: LogTailReader?
    private var watchdogReader: LogTailReader?
    private var cancellables: Set<AnyCancellable> = []

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func start(paths: ProviderPaths = .current) {
        stop()
        stderrReader = attachReader(fileURL: paths.launchdStderrLog)
        stdoutReader = attachReader(fileURL: paths.launchdStdoutLog)
        watchdogReader = attachReader(fileURL: paths.watchdogLog)
        Task { @MainActor [weak self] in
            await self?.stderrReader?.readAvailable()
            await self?.stdoutReader?.readAvailable()
            await self?.watchdogReader?.readAvailable()
            self?.mergePublishedLines()
        }
    }

    func stop() {
        cancellables.removeAll()
        stderrReader?.stop()
        stdoutReader?.stop()
        watchdogReader?.stop()
        stderrReader = nil
        stdoutReader = nil
        watchdogReader = nil
        lines = []
        watchdogLines = []
    }

    @discardableResult
    private func attachReader(fileURL: URL) -> LogTailReader {
        let reader = LogTailReader(fileURL: fileURL, capacity: capacity)
        reader.start()
        reader.$lines
            .sink { [weak self] _ in
                self?.mergePublishedLines()
            }
            .store(in: &cancellables)
        return reader
    }

    private func mergePublishedLines() {
        var merged: [String] = []
        merged.append(contentsOf: stderrReader?.lines ?? [])
        merged.append(contentsOf: stdoutReader?.lines ?? [])
        if merged.count > capacity {
            merged.removeFirst(merged.count - capacity)
        }
        lines = merged
        watchdogLines = watchdogReader?.lines ?? []
    }
}
