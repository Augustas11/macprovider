import Combine
import Foundation

/// Tails launchd provider stdout/stderr logs into one redacted line buffer for UI + diagnostics.
@MainActor
final class ProviderLogTail: ObservableObject {
    @Published private(set) var lines: [String] = []

    private let capacity: Int
    private var stderrReader: LogTailReader?
    private var stdoutReader: LogTailReader?
    private var cancellables: Set<AnyCancellable> = []

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func start(paths: ProviderPaths = .current) {
        stop()
        stderrReader = attachReader(fileURL: paths.launchdStderrLog)
        stdoutReader = attachReader(fileURL: paths.launchdStdoutLog)
        Task { @MainActor [weak self] in
            await self?.stderrReader?.readAvailable()
            await self?.stdoutReader?.readAvailable()
            self?.mergePublishedLines()
        }
    }

    func stop() {
        cancellables.removeAll()
        stderrReader?.stop()
        stdoutReader?.stop()
        stderrReader = nil
        stdoutReader = nil
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
    }
}
