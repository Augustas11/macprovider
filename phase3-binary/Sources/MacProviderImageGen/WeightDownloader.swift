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
            let download = ImageFileDownload(source: source, destination: partial, resume: resume) { bytes in
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

private final class ImageFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let source: URL
    let destination: URL
    let resume: URL
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var receivedFile = false
    private var failure: Error?

    init(source: URL, destination: URL, resume: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.source = source
        self.destination = destination
        self.resume = resume
        self.progress = progress
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let download: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resume) {
                    download = session.downloadTask(withResumeData: data)
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
            download?.cancel(byProducingResumeData: { data in
                guard let data else { return }
                try? data.write(to: self.resume, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.resume.path)
            })
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              [200, 206].contains(response.statusCode) else {
            failure = ImageRuntimeError.downloadFailed((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            receivedFile = true
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
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
