import Darwin
import Foundation

enum MalibuCatalogReadError: Error { case responseTooLarge }

struct MalibuCatalogRead: Sendable {
    enum Mode: String, Sendable { case quick, verify, result }
    let id: String
    let mode: Mode
    var target: String? = nil
    var modelKey: String? = nil
    var context: String? = nil
    var transactionID: String? = nil
    var generation: String? = nil
    init(mode: Mode, id: String = UUID().uuidString.lowercased(), target: String? = nil, modelKey: String? = nil,
         context: String? = nil, transactionID: String? = nil, generation: String? = nil) {
        self.mode = mode; self.id = id; self.target = target; self.modelKey = modelKey; self.context = context
        self.transactionID = transactionID; self.generation = generation
    }
    var timeout: TimeInterval { mode == .verify ? 1800 : 10 }
    func arguments(paths: ProviderPaths) throws -> [String] {
        guard malibuCanonicalUUID(id) else { throw ModelManagementError.invalidCatalog }
        var arguments: [String]
        if mode == .result {
            guard let transactionID, malibuCanonicalUUID(transactionID), let generation, malibuCanonicalUUID(generation), let target else { throw ModelManagementError.invalidCatalog }
            arguments = ["models", "transaction", "result", transactionID, "--model", target, "--expected-kind", "evaluate_model", "--operation-generation", generation, "--json", "--config", paths.configFile.path]
        } else {
            arguments = ["models", "catalog-economics", "--json", "--config", paths.configFile.path, "--local-activation"]
        }
        arguments += ["--app-read-request", id, "--app-read-mode", mode.rawValue, "--read-lock-fd", "199", "--read-lifetime-fd", "200"]
        if mode != .quick {
            guard let context, malibuDigest(context), let target, !target.isEmpty, target.utf8.count <= 256,
                  let modelKey, !modelKey.isEmpty else { throw ModelManagementError.invalidCatalog }
            if mode == .verify { arguments += ["--verify-local-model", target] }
            arguments += ["--expected-context-sha256", context]
        } else if target != nil || context != nil || transactionID != nil || generation != nil { throw ModelManagementError.invalidCatalog }
        return arguments
    }
}

struct MalibuCatalogReadProgress: Sendable {
    let bytes: UInt64
    let elapsed: TimeInterval
}

struct MalibuCatalogReadTranscript {
    private(set) var sequence: UInt64 = 0
    private(set) var bytes: UInt64 = 0
    private(set) var terminal = false
    private(set) var projection: Data?
    private(set) var failure: String?
    mutating func consume(_ data: Data, read: MalibuCatalogRead) throws {
        guard !terminal, data.count <= 1_048_576, sequence < 4096 else { throw ModelManagementError.invalidCatalog }
        try MalibuStrictJSON.rejectDuplicateKeys(data)
        struct Event: Decodable {
            let schema: String, requestID: String, target: String, key: String, kind: String
            let sequence: UInt64, bytes: UInt64
            let error: String?
            let projection: MalibuModelCatalogEconomicsDocument?
            enum CodingKeys: String, CodingKey, CaseIterable {
                case schema, requestID = "request_id", target = "target_model_id", key = "model_key", kind
                case sequence = "event_sequence", bytes = "bytes_completed", error = "error_code", projection
            }
            init(from decoder: Decoder) throws {
                try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.stringValue))
                let c = try decoder.container(keyedBy: CodingKeys.self)
                guard Set(c.allKeys) == Set(CodingKeys.allCases) else { throw ModelManagementError.invalidCatalog }
                schema = try c.decode(String.self, forKey: .schema); requestID = try c.decode(String.self, forKey: .requestID)
                target = try c.decode(String.self, forKey: .target); key = try c.decode(String.self, forKey: .key)
                kind = try c.decode(String.self, forKey: .kind); sequence = try c.decode(UInt64.self, forKey: .sequence)
                bytes = try c.decode(UInt64.self, forKey: .bytes); error = try c.decodeIfPresent(String.self, forKey: .error)
                projection = try c.decodeIfPresent(MalibuModelCatalogEconomicsDocument.self, forKey: .projection)
            }
        }
        let event = try JSONDecoder().decode(Event.self, from: data)
        guard event.schema == "model_catalog_read_event.v1", event.requestID == read.id,
              event.target == read.target, event.key == read.modelKey, event.sequence == sequence + 1,
              event.bytes >= bytes, ["accepted", "progress", "completed", "failed"].contains(event.kind),
              sequence != 0 || event.kind == "accepted" || event.kind == "failed",
              event.kind != "accepted" || (sequence == 0 && event.bytes == 0),
              event.kind == "completed" || event.projection == nil,
              event.kind == "failed" || event.error == nil else { throw ModelManagementError.invalidCatalog }
        if event.kind == "failed" {
            guard let code = event.error, ["verification_incomplete", "artifact_invalid", "authority_changed", "context_changed", "read_limit_exceeded"].contains(code) else { throw ModelManagementError.invalidCatalog }
            failure = code; terminal = true
        } else if event.kind == "completed" {
            guard sequence > 0, let document = event.projection else { throw ModelManagementError.invalidCatalog }
            _ = try document.validated(localActivationNegotiated: true)
            guard document.source.projectionProtocolVersion == "2", document.source.transactionContextSHA256 == read.context,
                  let target = read.target, let key = read.modelKey,
                  document.hasVerifiedLocalTarget(target, modelKey: key) else { throw ModelManagementError.invalidCatalog }
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            projection = try JSONSerialization.data(withJSONObject: object["projection"]!, options: [.sortedKeys])
            terminal = true
        }
        sequence = event.sequence; bytes = event.bytes
    }
}

struct MalibuCatalogReadLiveness {
    let started: UInt64
    private var lastEvent: UInt64
    private var lastByteAdvance: UInt64
    private var hasEvent = false
    private var bytes: UInt64 = 0
    init(started: UInt64) { self.started = started; lastEvent = started; lastByteAdvance = started }
    mutating func observe(bytes: UInt64, now: UInt64) {
        hasEvent = true; lastEvent = now
        if bytes > self.bytes { lastByteAdvance = now }
        self.bytes = bytes
    }
    func expired(now: UInt64) -> Bool {
        (!hasEvent && now - started >= 10_000_000_000)
            || now - lastEvent >= 15_000_000_000
            || (bytes > 0 && now - lastByteAdvance >= 60_000_000_000)
    }
}

// This worker is independent from the short transaction-control worker. Its
// reservation outlives UI timeout and lasts through exact child exit/reap.
final class MalibuCatalogReadRunner: @unchecked Sendable {
    static let shared = MalibuCatalogReadRunner()
    private let worker = MalibuTransactionWorker()
    private let lock = NSLock()
    private var request: MalibuTransactionRequest?
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return request != nil }
    func cancel() { lock.lock(); let current = request; lock.unlock(); current?.revoke() }
    private func reserve(_ value: MalibuTransactionRequest) throws {
        lock.lock(); defer { lock.unlock() }
        guard request == nil else { throw MalibuTransactionRequest.Failure.busy }; request = value
    }
    private func release(_ value: MalibuTransactionRequest) {
        lock.lock(); defer { lock.unlock() }
        if request?.nonce == value.nonce { request = nil }
    }

    func run(read: MalibuCatalogRead, paths: ProviderPaths, timeout: TimeInterval? = nil,
             resolve: @escaping @Sendable () throws -> URL,
             onSpawn: @escaping @Sendable ([String], pid_t) -> Void = { _, _ in },
             progress: @escaping @MainActor @Sendable (MalibuCatalogReadProgress) -> Void) async throws -> ModelCLIResult {
        let request = MalibuTransactionRequest(timeout: min(timeout ?? read.timeout, read.timeout))
        try reserve(request)
        defer {
            if !worker.isBusy { release(request) }
            else {
                Task { [self] in
                    while worker.isBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
                    release(request)
                }
            }
        }
        return try await worker.run(request: request) { request in
            try request.check()
            let lease = try Self.openLock(paths: paths); defer { close(lease) }
            let executable = try resolve()
            let environment = try ProcessEnvironmentSanitizer.sanitized()
            let arguments = try read.arguments(paths: paths)
            try request.check()
            return try Self.execute(executable: executable, arguments: arguments, environment: environment,
                                    lease: lease, read: read, request: request, onSpawn: onSpawn, progress: progress)
        }
    }
    static func openLock(paths: ProviderPaths) throws -> Int32 {
        let directory = MalibuTransactionFiles.directory(paths)
        try MalibuTransactionFiles.ensureDirectory(directory)
        let fd = open(directory.appendingPathComponent("catalog-read.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, MalibuTransactionFiles.noACL(fd), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw MalibuTransactionRequest.Failure.busy
        }
        return fd
    }
    static func execute(executable: URL, arguments: [String], environment: [String: String], lease: Int32,
                        read: MalibuCatalogRead, request: MalibuTransactionRequest,
                        onSpawn: @escaping @Sendable ([String], pid_t) -> Void = { _, _ in },
                        progress: @escaping @MainActor @Sendable (MalibuCatalogReadProgress) -> Void) throws -> ModelCLIResult {
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        func high(_ fd: Int32) throws -> Int32 {
            guard fd >= 0 else { throw ModelManagementError.invalidCatalog }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 210); close(fd)
            guard copy >= 0 else { throw ModelManagementError.invalidCatalog }
            descriptors.append(copy); return copy
        }
        func pipePair() throws -> (Int32, Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw ModelManagementError.invalidCatalog }
            let first: Int32
            do { first = try high(fds[0]) }
            catch { close(fds[1]); throw error }
            return (first, try high(fds[1]))
        }
        func closeOwned(_ fd: Int32) { if descriptors.contains(fd) { close(fd); descriptors.removeAll { $0 == fd } } }
        let output = try pipePair(), errors = try pipePair(), lifetime = try pipePair(), lockCopy = try high(dup(lease))
        let null = try high(open("/dev/null", O_RDONLY | O_CLOEXEC))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ModelManagementError.invalidCatalog }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, target) in [(null, STDIN_FILENO), (output.1, STDOUT_FILENO), (errors.1, STDERR_FILENO), (lockCopy, 199), (lifetime.0, 200)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw ModelManagementError.invalidCatalog }
        }
        for fd in descriptors { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw ModelManagementError.invalidCatalog } }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + env { if let value { free(value) } } }
        var child: pid_t = 0, status: Int32 = 0
        try request.commitSpawn()
        let result = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&child, executable.path, &actions, nil, a.baseAddress!, e.baseAddress!) } }
        guard result == 0 else { throw ModelManagementError.invalidCatalog }
        onSpawn(arguments, child)
        var reaped = false
        defer { if !reaped { kill(child, SIGKILL); while waitpid(child, nil, 0) < 0 && errno == EINTR {} } }
        closeOwned(output.1); closeOwned(errors.1); closeOwned(lifetime.0)
        guard fcntl(output.0, F_SETFL, O_NONBLOCK) == 0, fcntl(errors.0, F_SETFL, O_NONBLOCK) == 0 else { throw ModelManagementError.invalidCatalog }
        let started = request.startedAt
        var liveness = MalibuCatalogReadLiveness(started: started)
        var stdout = Data(), stderr = Data(), partial = Data(), streams: Set<Int32> = [output.0, errors.0]
        var transcript = MalibuCatalogReadTranscript(), failed = false, terminatedAt: UInt64?
        while !reaped || !streams.isEmpty {
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(now - started) / 1_000_000_000
            if (try? request.check()) == nil { failed = true }
            if read.mode == .verify && liveness.expired(now: now) { failed = true }
            if failed {
                closeOwned(lifetime.1)
                if !reaped {
                    if terminatedAt == nil { kill(child, SIGTERM); terminatedAt = now }
                    else if now - terminatedAt! >= 1_000_000_000 { kill(child, SIGKILL) }
                } else { streams.removeAll(); break }
            }
            var polls = streams.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
            _ = poll(&polls, nfds_t(polls.count), 20)
            for item in polls where item.revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(item.fd, &buffer, buffer.count)
                if count == 0 { streams.remove(item.fd); continue }
                if count < 0 { if errno != EAGAIN && errno != EINTR { failed = true }; continue }
                let data = Data(buffer.prefix(count))
                if item.fd == errors.0 {
                    if stderr.count + count > 65536 { failed = true } else { stderr.append(data) }
                } else {
                    if stdout.count + count > 8 * 1_048_576 { failed = true; continue }
                    stdout.append(data)
                    if read.mode == .verify && !failed {
                        partial.append(data)
                        while let newline = partial.firstIndex(of: 10) {
                            do {
                                try transcript.consume(Data(partial.prefix(upTo: newline)), read: read)
                                liveness.observe(bytes: transcript.bytes, now: now)
                                let update = MalibuCatalogReadProgress(bytes: transcript.bytes, elapsed: elapsed)
                                Task { @MainActor in if (try? request.check()) != nil { progress(update) } }
                            } catch { failed = true }
                            partial.removeSubrange(...newline)
                            if failed { break }
                        }
                        if partial.count > 1_048_576 { failed = true }
                    }
                }
            }
            if !reaped {
                let waited = waitpid(child, &status, WNOHANG)
                if waited == child { reaped = true }
                else if waited < 0 && errno != EINTR {
                    // ECHILD means this PID is no longer ours to signal.
                    if errno == ECHILD { reaped = true }
                    throw ModelManagementError.invalidCatalog
                }
            }
        }
        let exitCode: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        guard !failed, (try? request.check()) != nil, let errorText = String(data: stderr, encoding: .utf8) else { throw ModelManagementError.invalidCatalog }
        if read.mode == .verify {
            if partial.isEmpty, transcript.terminal, transcript.failure == "read_limit_exceeded" { throw MalibuCatalogReadError.responseTooLarge }
            guard partial.isEmpty, transcript.terminal, transcript.failure == nil, exitCode == 0, let projection = transcript.projection,
                  let text = String(data: projection, encoding: .utf8) else { throw ModelManagementError.invalidCatalog }
            return .init(exitCode: 0, stdout: text, stderr: errorText)
        }
        if exitCode != 0, errorText.split(whereSeparator: \.isNewline).contains(where: { $0 == "Error: read_limit_exceeded" }) { throw MalibuCatalogReadError.responseTooLarge }
        guard let text = String(data: stdout, encoding: .utf8) else { throw ModelManagementError.invalidCatalog }
        return .init(exitCode: exitCode, stdout: text, stderr: errorText)
    }
}

extension MalibuModelCLI {
    var catalogReadIsBusy: Bool { MalibuCatalogReadRunner.shared.isBusy }
    func cancelCatalogRead() { MalibuCatalogReadRunner.shared.cancel() }
    func readCatalog(_ read: MalibuCatalogRead, paths: ProviderPaths, peer: MalibuModelPeerEvidence,
                     timeout: TimeInterval, progress: @escaping @MainActor @Sendable (MalibuCatalogReadProgress) -> Void) async throws -> ModelCLIResult {
        guard Self.supportsCatalogRead(peer) else { throw ModelManagementError.invalidCatalog }
        return try await MalibuCatalogReadRunner.shared.run(read: read, paths: paths, timeout: timeout, resolve: { [self] in
            guard Self.supportsCatalogRead(peer) else { throw ModelManagementError.invalidCatalog }
            return try resolveExecutable(peer: peer)
        }, progress: progress)
    }
    nonisolated static func supportsCatalogRead(_ peer: MalibuModelPeerEvidence) -> Bool {
        [MalibuModelCapabilityManifest.catalogEconomics, MalibuModelCapabilityManifest.catalogTransactions,
         MalibuModelCapabilityManifest.localActivation, MalibuModelCapabilityManifest.recommendationAdoption,
         MalibuModelCapabilityManifest.catalogReadLifecycle].allSatisfy { MalibuModelCapabilityManifest.checkedIn.supports($0, peer: peer) }
    }
}
