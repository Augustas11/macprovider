import Foundation

/// URLSession downloads stream directly to disk. Its resume data preserves partial
/// transfers without retaining multi-gigabyte weights in process memory.
enum ImageWeightDownloader {
    static func prepare(
        directory: URL, progress: @escaping @Sendable (ImageDownloadProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var completed: Int64 = 0
        progress(.init(completedBytes: 0, totalBytes: SDXLTurboManifest.totalBytes))
        for file in SDXLTurboManifest.files {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: target.path) {
                do {
                    try file.verify(at: target)
                    completed += file.size
                    progress(.init(completedBytes: completed, totalBytes: SDXLTurboManifest.totalBytes))
                    continue
                } catch is CancellationError { throw CancellationError() }
                catch { try fm.removeItem(at: target) }
            }
            let partial = target.appendingPathExtension("partial")
            let resume = target.appendingPathExtension("resume")
            let base = completed
            let source = URL(string: "https://huggingface.co/\(SDXLTurboManifest.repository)/resolve/\(SDXLTurboManifest.revision)/\(file.path)")!
            let download = ImageFileDownload(source: source, destination: partial, resume: resume, expectedSize: file.size) { bytes in
                progress(.init(completedBytes: base + min(bytes, file.size), totalBytes: SDXLTurboManifest.totalBytes))
            }
            try await download.run()
            do { try file.verify(at: partial) }
            catch {
                try? fm.removeItem(at: partial)
                try? fm.removeItem(at: resume)
                throw error
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            try fm.moveItem(at: partial, to: target)
            try? fm.removeItem(at: resume)
            completed += file.size
            progress(.init(completedBytes: completed, totalBytes: SDXLTurboManifest.totalBytes))
        }
    }
}

final class ImageFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let source: URL
    let destination: URL
    let resume: URL
    let expectedSize: Int64
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var receivedFile = false
    private var failure: Error?
    private var resumedOffset: Int64 = 0
    private var attemptBytes: Int64 = 0
    private var hasReplacementResumeData = false

    init(source: URL, destination: URL, resume: URL, expectedSize: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.source = source
        self.destination = destination
        self.resume = resume
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(attempt: ((Data?) async throws -> Void)? = nil) async throws {
        let performAttempt = attempt ?? { try await self.runAttempt(resumeData: $0) }
        try Task.checkCancellation()
        let resumeData = try? Data(contentsOf: resume)
        // Consume the checkpoint before trying it. URLSession can reject stale resume
        // data without producing a replacement; it must never poison future requests.
        try? FileManager.default.removeItem(at: resume)
        do {
            try await performAttempt(resumeData)
        } catch {
            guard resumeData != nil, !cancelled, failure == nil,
                  !hasReplacementResumeData, !(error is CancellationError), !Task.isCancelled else { throw error }
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: destination)
            try await performAttempt(nil)
        }
    }

    private func runAttempt(resumeData: Data?) async throws {
        receivedFile = false
        failure = nil
        resumedOffset = 0
        attemptBytes = 0
        hasReplacementResumeData = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let download: URLSessionDownloadTask
                if let resumeData {
                    download = session.downloadTask(withResumeData: resumeData)
                } else {
                    download = session.downloadTask(with: source)
                }
                lock.lock()
                self.continuation = continuation
                task = download
                let shouldCancel = cancelled
                lock.unlock()
                download.resume()
                if shouldCancel { download.cancel() }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let download = self.task
            self.lock.unlock()
            download?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard failure == nil else { downloadTask.cancel(); return }
        do {
            try validate(response: downloadTask.response)
            // Count the resumed prefix even on platforms reporting only this attempt's
            // body bytes in totalBytesWritten. Reject before publishing progress.
            let (sum, overflow) = attemptBytes.addingReportingOverflow(bytesWritten)
            let (cumulative, offsetOverflow) = resumedOffset.addingReportingOverflow(sum)
            guard bytesWritten >= 0, !overflow, !offsetOverflow,
                  max(totalBytesWritten, cumulative) <= expectedSize,
                  totalBytesExpectedToWrite <= expectedSize else {
                throw ImageRuntimeError.invalidWeights(source.lastPathComponent)
            }
            attemptBytes = sum
            progress(max(totalBytesWritten, cumulative))
        } catch {
            failure = error
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        guard fileOffset >= 0, fileOffset <= expectedSize,
              expectedTotalBytes == NSURLSessionTransferSizeUnknown ||
                expectedTotalBytes == expectedSize || expectedTotalBytes == expectedSize - fileOffset else {
            failure = ImageRuntimeError.invalidWeights(source.lastPathComponent)
            downloadTask.cancel()
            return
        }
        resumedOffset = fileOffset
    }

    /// Check the pinned full-file size, rather than trusting a CDN's body length.
    func validate(response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse,
              [200, 206].contains(response.statusCode) else {
            throw ImageRuntimeError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var bodySize = expectedSize
        if response.statusCode == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  range.hasPrefix("bytes ") else {
                throw ImageRuntimeError.invalidWeights(source.lastPathComponent)
            }
            let bounds = range.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            let span = bounds.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
            guard bounds.count == 2, span.count == 2,
                  let start = Int64(span[0]), let end = Int64(span[1]), let total = Int64(bounds[1]),
                  start >= 0, start <= end, total == expectedSize, end == expectedSize - 1,
                  start == resumedOffset else {
                throw ImageRuntimeError.invalidWeights(source.lastPathComponent)
            }
            bodySize = expectedSize - start
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length") {
            guard Int64(length) == bodySize else {
                throw ImageRuntimeError.invalidWeights(source.lastPathComponent)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard failure == nil else { return }
        do {
            try validate(response: downloadTask.response)
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == expectedSize else {
                throw ImageRuntimeError.invalidWeights(source.lastPathComponent)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            receivedFile = true
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if failure != nil {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: resume)
        } else if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            hasReplacementResumeData = true
            try? data.write(to: resume, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resume.path)
        }
        lock.lock()
        let completion = continuation
        continuation = nil
        let wasCancelled = cancelled
        self.task = nil
        lock.unlock()
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { completion?.resume(throwing: error) }
        else if receivedFile { completion?.resume() }
        else { completion?.resume(throwing: ImageRuntimeError.downloadFailed(0)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Public pinned weights carry no authorization. Permit HTTPS CDN redirects only.
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
