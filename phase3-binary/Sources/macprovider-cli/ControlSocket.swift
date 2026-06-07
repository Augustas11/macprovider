import Darwin
import Foundation
import MacProviderCore

public enum SwitchAckReason: String, Sendable, Equatable {
    case loadingInProgress = "loading_in_progress"
    case cooldown
    case notInSupportedModels = "not_in_supported_models"
    case other
}

public enum SwitchProgressState: String, Sendable, Equatable {
    case loading
    case draining
    case loaded
    case failed
}

public enum ControlSocketFrame: Equatable, Sendable {
    case switchRequest(targetModelID: String, requestedAtMs: Int64)
    case statusRequest
    case switchAck(accepted: Bool, reason: SwitchAckReason?, currentTarget: String?, secondsRemaining: Int?)
    case switchProgress(state: SwitchProgressState, elapsedMs: Int, reason: String?)
    case statusResponse(currentModelID: String, runtimeState: SwapState)
}

public enum ControlSocketCodec {
    public static func encode(_ frame: ControlSocketFrame) throws -> Data {
        let object: [String: Any]
        switch frame {
        case let .switchRequest(targetModelID, requestedAtMs):
            object = [
                "type": "switch_request",
                "target_model_id": targetModelID,
                "requested_at_ms": requestedAtMs,
            ]
        case .statusRequest:
            object = ["type": "status_request"]
        case let .switchAck(accepted, reason, currentTarget, secondsRemaining):
            var frame: [String: Any] = [
                "type": "switch_ack",
                "accepted": accepted,
            ]
            if !accepted, let reason {
                frame["reason"] = reason.rawValue
                if reason == .loadingInProgress, let currentTarget {
                    frame["current_target"] = currentTarget
                }
                if reason == .cooldown, let secondsRemaining {
                    frame["seconds_remaining"] = secondsRemaining
                }
            }
            object = frame
        case let .switchProgress(state, elapsedMs, reason):
            var frame: [String: Any] = [
                "type": "switch_progress",
                "state": state.rawValue,
                "elapsed_ms": elapsedMs,
            ]
            if state == .failed, let reason {
                frame["reason"] = reason
            }
            object = frame
        case let .statusResponse(currentModelID, runtimeState):
            object = [
                "type": "status_response",
                "current_model_id": currentModelID,
                "runtime_state": runtimeState.rawValue,
            ]
        }

        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> ControlSocketFrame {
        let trimmed = line.last == 0x0A ? line.dropLast() : line[...]
        let raw = try JSONSerialization.jsonObject(with: Data(trimmed))
        guard let object = raw as? [String: Any] else {
            throw ControlSocketError.missingType
        }
        guard let type = object["type"] as? String else {
            throw ControlSocketError.missingType
        }

        switch type {
        case "switch_request":
            return .switchRequest(
                targetModelID: try stringField("target_model_id", in: object),
                requestedAtMs: try int64Field("requested_at_ms", in: object)
            )
        case "status_request":
            return .statusRequest
        case "switch_ack":
            let accepted = try boolField("accepted", in: object)
            if accepted {
                return .switchAck(accepted: true, reason: nil, currentTarget: nil, secondsRemaining: nil)
            }
            let reasonRaw = try stringField("reason", in: object)
            guard let reason = SwitchAckReason(rawValue: reasonRaw) else {
                throw ControlSocketError.invalidEnumValue(field: "reason", value: reasonRaw)
            }
            let currentTarget = reason == .loadingInProgress ? try stringField("current_target", in: object) : nil
            let secondsRemaining = reason == .cooldown ? try intField("seconds_remaining", in: object) : nil
            return .switchAck(
                accepted: false,
                reason: reason,
                currentTarget: currentTarget,
                secondsRemaining: secondsRemaining
            )
        case "switch_progress":
            let stateRaw = try stringField("state", in: object)
            guard let state = SwitchProgressState(rawValue: stateRaw) else {
                throw ControlSocketError.invalidEnumValue(field: "state", value: stateRaw)
            }
            let reason = state == .failed ? try stringField("reason", in: object) : nil
            return .switchProgress(state: state, elapsedMs: try intField("elapsed_ms", in: object), reason: reason)
        case "status_response":
            let stateRaw = try stringField("runtime_state", in: object)
            guard let state = SwapState(rawValue: stateRaw), state != .failed else {
                throw ControlSocketError.invalidEnumValue(field: "runtime_state", value: stateRaw)
            }
            return .statusResponse(
                currentModelID: try stringField("current_model_id", in: object),
                runtimeState: state
            )
        default:
            throw ControlSocketError.unknownType(type)
        }
    }

    private static func stringField(_ field: String, in object: [String: Any]) throws -> String {
        guard let value = object[field] as? String else {
            throw ControlSocketError.missingRequiredField(field)
        }
        return value
    }

    private static func boolField(_ field: String, in object: [String: Any]) throws -> Bool {
        guard let value = object[field] as? Bool else {
            throw ControlSocketError.missingRequiredField(field)
        }
        return value
    }

    private static func intField(_ field: String, in object: [String: Any]) throws -> Int {
        if let value = object[field] as? Int {
            return value
        }
        if let value = object[field] as? NSNumber {
            return value.intValue
        }
        throw ControlSocketError.missingRequiredField(field)
    }

    private static func int64Field(_ field: String, in object: [String: Any]) throws -> Int64 {
        if let value = object[field] as? Int64 {
            return value
        }
        if let value = object[field] as? Int {
            return Int64(value)
        }
        if let value = object[field] as? NSNumber {
            return value.int64Value
        }
        throw ControlSocketError.missingRequiredField(field)
    }
}

public enum ControlSocketError: Error, Equatable {
    case missingType
    case unknownType(String)
    case missingRequiredField(String)
    case invalidEnumValue(field: String, value: String)
}

public enum ControlSocketPaths {
    public static func resolve(ctlSocketPath: String?) -> URL {
        if let ctlSocketPath, !ctlSocketPath.isEmpty {
            return URL(fileURLWithPath: (ctlSocketPath as NSString).expandingTildeInPath)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-cli")
            .appendingPathComponent("ctl.sock")
    }

    public static func defaultSwitchStatePath(_ switchStatePath: String?) -> URL {
        if let switchStatePath, !switchStatePath.isEmpty {
            return URL(fileURLWithPath: (switchStatePath as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider-cli/last-switch.ts")
    }
}

public enum ControlSocketConnectError: Error, Equatable {
    case socketAbsent(path: String)
    case connectionRefused(path: String)
    case handshakeTimeout(path: String)
    case other(underlying: String)
}

public enum ControlSocketServerError: Error, CustomStringConvertible, Equatable {
    case staleSocket(path: String)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case socketFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .staleSocket(path):
            return "control socket \(path) already exists; remove the stale file and restart serve"
        case let .bindFailed(path, errno):
            return "control socket \(path) bind failed: \(String(cString: strerror(errno)))"
        case let .listenFailed(errno):
            return "control socket listen failed: \(String(cString: strerror(errno)))"
        case let .socketFailed(errno):
            return "control socket creation failed: \(String(cString: strerror(errno)))"
        }
    }
}

public enum ControlSocketConnectionError: Error, Equatable {
    case closed
    case timedOut
    case frameTooLarge(size: Int)
}

actor ControlSocketServer {
    private let socketPath: URL
    private let modelRuntime: ModelRuntime
    private let supportedModels: [String]?
    private let idleTimeoutSeconds: TimeInterval
    private let tracker = ControlSocketSwitchTracker()
    private var listenerFD: Int32?
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [UUID: Task<Void, Never>] = [:]
    private var clientFDs: [Int32] = []

    init(
        socketPath: URL,
        modelRuntime: ModelRuntime,
        supportedModels: [String]? = nil,
        idleTimeoutSeconds: TimeInterval = 30.0
    ) {
        self.socketPath = socketPath
        self.modelRuntime = modelRuntime
        self.supportedModels = supportedModels
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    func start() async throws {
        let parent = socketPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        chmod(parent.path, S_IRWXU)

        if FileManager.default.fileExists(atPath: socketPath.path) {
            let error = ControlSocketServerError.staleSocket(path: socketPath.path)
            FileHandle.standardError.write(Data(("\(error.description)\n").utf8))
            throw error
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketServerError.socketFailed(errno: errno)
        }

        do {
            try bindUnixSocket(fd: fd, path: socketPath.path)
        } catch let error as ControlSocketServerError {
            close(fd)
            if case let .bindFailed(_, err) = error, err == EADDRINUSE {
                let stale = ControlSocketServerError.staleSocket(path: socketPath.path)
                FileHandle.standardError.write(Data(("\(stale.description)\n").utf8))
                throw stale
            }
            throw error
        }

        chmod(socketPath.path, S_IRUSR | S_IWUSR)
        guard Darwin.listen(fd, 128) == 0 else {
            let err = errno
            close(fd)
            try? FileManager.default.removeItem(at: socketPath)
            throw ControlSocketServerError.listenFailed(errno: err)
        }

        listenerFD = fd
        let runtime = modelRuntime
        let tracker = tracker
        let supportedModels = supportedModels
        let idleTimeoutSeconds = idleTimeoutSeconds
        acceptTask = Task.detached(priority: .userInitiated) {
            await Self.acceptLoop(
                listenerFD: fd,
                modelRuntime: runtime,
                tracker: tracker,
                supportedModels: supportedModels,
                idleTimeoutSeconds: idleTimeoutSeconds,
                server: self
            )
        }
    }

    func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        for task in clientTasks.values {
            task.cancel()
        }
        clientTasks.removeAll()
        for fd in clientFDs {
            close(fd)
        }
        clientFDs.removeAll()
        if let listenerFD {
            close(listenerFD)
            self.listenerFD = nil
        }
        try? FileManager.default.removeItem(at: socketPath)
        await tracker.clear()
    }

    func clientTasksCountForTest() -> Int {
        clientTasks.count
    }

    private func appendClientTask(id: UUID, task: Task<Void, Never>) {
        clientTasks[id] = task
    }

    private func removeClientTask(_ id: UUID) {
        clientTasks.removeValue(forKey: id)
    }

    private func appendClientFD(_ fd: Int32) {
        clientFDs.append(fd)
    }

    private func removeClientFD(_ fd: Int32) {
        clientFDs.removeAll { $0 == fd }
    }

    private nonisolated static func acceptLoop(
        listenerFD: Int32,
        modelRuntime: ModelRuntime,
        tracker: ControlSocketSwitchTracker,
        supportedModels: [String]?,
        idleTimeoutSeconds: TimeInterval,
        server: ControlSocketServer
    ) async {
        while !Task.isCancelled {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            await server.appendClientFD(clientFD)
            let taskID = UUID()
            let task = Task.detached(priority: .userInitiated) { [server] in
                defer {
                    Task { await server.removeClientTask(taskID) }
                }
                await handleClient(
                    fd: clientFD,
                    modelRuntime: modelRuntime,
                    tracker: tracker,
                    supportedModels: supportedModels,
                    idleTimeoutSeconds: idleTimeoutSeconds
                )
                await server.removeClientFD(clientFD)
            }
            await server.appendClientTask(id: taskID, task: task)
        }
    }

    private nonisolated static func handleClient(
        fd: Int32,
        modelRuntime: ModelRuntime,
        tracker: ControlSocketSwitchTracker,
        supportedModels: [String]?,
        idleTimeoutSeconds: TimeInterval
    ) async {
        let connection = ControlSocketConnection(fd: fd)
        while !Task.isCancelled {
            do {
                let frame = try await connection.receive(timeout: idleTimeoutSeconds)
                switch frame {
                case .statusRequest:
                    let snapshot = await modelRuntime.currentSnapshot()
                    let state = snapshot.state == .failed ? SwapState.ready : snapshot.state
                    try await connection.send(.statusResponse(currentModelID: snapshot.modelID ?? "", runtimeState: state))
                case let .switchRequest(targetModelID, requestedAtMs):
                    await handleSwitchRequest(
                        targetModelID: targetModelID,
                        requestedAtMs: requestedAtMs,
                        connection: connection,
                        modelRuntime: modelRuntime,
                        tracker: tracker,
                        supportedModels: supportedModels
                    )
                    await connection.close()
                    return
                default:
                    FileHandle.standardError.write(Data("control socket received unexpected frame type; closing connection\n".utf8))
                    await connection.close()
                    return
                }
            } catch let error as ControlSocketError {
                FileHandle.standardError.write(Data("control socket decode error: \(error); closing connection\n".utf8))
                await connection.close()
                return
            } catch ControlSocketConnectionError.closed {
                await connection.close()
                return
            } catch ControlSocketConnectError.other(let underlying) where Task.isCancelled && underlying == "Bad file descriptor" {
                await connection.close()
                return
            } catch {
                FileHandle.standardError.write(Data("control socket error: \(error); closing connection\n".utf8))
                await connection.close()
                return
            }
        }
        await connection.close()
    }

    private nonisolated static func handleSwitchRequest(
        targetModelID: String,
        requestedAtMs: Int64,
        connection: ControlSocketConnection,
        modelRuntime: ModelRuntime,
        tracker: ControlSocketSwitchTracker,
        supportedModels: [String]?
    ) async {
        do {
            do {
                _ = try SupportedModels.validate(model: targetModelID, supportedModels: supportedModels)
            } catch SupportedModelsValidationError.modelNotInCatalog {
                try? await connection.send(.switchAck(
                    accepted: false,
                    reason: .notInSupportedModels,
                    currentTarget: nil,
                    secondsRemaining: nil
                ))
                await connection.close()
                return
            } catch {
                try? await connection.send(.switchAck(accepted: false, reason: .other, currentTarget: nil, secondsRemaining: nil))
                await connection.close()
                return
            }

            let stream = await modelRuntime.swapSignals()
            _ = try await modelRuntime.beginSwap(targetModelID: targetModelID)
            await tracker.start(targetModelID)
            try await connection.send(.switchAck(accepted: true, reason: nil, currentTarget: nil, secondsRemaining: nil))
            try await connection.send(.switchProgress(state: .loading, elapsedMs: elapsedMs(since: requestedAtMs), reason: nil))

            var iterator = stream.makeAsyncIterator()
            while let signal = await iterator.next() {
                guard signal.targetModelID == targetModelID else {
                    continue
                }
                switch signal.outcome {
                case .loadFinished:
                    try await connection.send(.switchProgress(state: .draining, elapsedMs: elapsedMs(since: requestedAtMs), reason: nil))
                    continue
                case .completed:
                    try await connection.send(.switchProgress(state: .loaded, elapsedMs: elapsedMs(since: requestedAtMs), reason: nil))
                case let .failed(reason):
                    try await connection.send(.switchProgress(state: .failed, elapsedMs: elapsedMs(since: requestedAtMs), reason: reason))
                }
                await tracker.clear()
                return
            }
        } catch RuntimeStateMachineError.notReady {
            let currentTarget = await tracker.currentTarget() ?? targetModelID
            try? await connection.send(.switchAck(
                accepted: false,
                reason: .loadingInProgress,
                currentTarget: currentTarget,
                secondsRemaining: nil
            ))
        } catch is WarmSwapDisabledError {
            try? await connection.send(.switchAck(accepted: false, reason: .other, currentTarget: nil, secondsRemaining: nil))
        } catch {
            try? await connection.send(.switchAck(accepted: false, reason: .other, currentTarget: nil, secondsRemaining: nil))
        }
    }

    private nonisolated static func elapsedMs(since requestedAtMs: Int64) -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return max(0, Int(now - requestedAtMs))
    }
}

private actor ControlSocketSwitchTracker {
    private var targetModelID: String?

    func start(_ targetModelID: String) {
        self.targetModelID = targetModelID
    }

    func currentTarget() -> String? {
        targetModelID
    }

    func clear() {
        targetModelID = nil
    }
}

public enum ControlSocketClient {
    public static func connect(socketPath: URL, timeout _: TimeInterval = 2.0) async throws -> ControlSocketConnection {
        let path = socketPath.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ControlSocketConnectError.socketAbsent(path: path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
        }

        do {
            try connectUnixSocket(fd: fd, path: path)
            return ControlSocketConnection(fd: fd)
        } catch {
            let err = errno
            close(fd)
            if err == ECONNREFUSED || err == ENOTSOCK || err == EPROTOTYPE {
                throw ControlSocketConnectError.connectionRefused(path: path)
            }
            throw ControlSocketConnectError.other(underlying: String(cString: strerror(err)))
        }
    }
}

public actor ControlSocketConnection {
    public static let maxFrameBytes = 64 * 1024

    private var fd: Int32?
    private var receiveBuffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    public func send(_ frame: ControlSocketFrame) async throws {
        let data = try ControlSocketCodec.encode(frame)
        try writeAll(data)
    }

    public func receive(timeout: TimeInterval? = nil) async throws -> ControlSocketFrame {
        while true {
            if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let frameSize = receiveBuffer.distance(from: receiveBuffer.startIndex, to: newline) + 1
                if frameSize > Self.maxFrameBytes {
                    throw ControlSocketConnectionError.frameTooLarge(size: frameSize)
                }
                let line = receiveBuffer.prefix(through: newline)
                receiveBuffer.removeSubrange(...newline)
                return try ControlSocketCodec.decode(Data(line))
            }

            guard let fd else {
                throw ControlSocketConnectionError.closed
            }
            if let timeout, !waitForReadable(fd: fd, timeout: timeout) {
                throw ControlSocketConnectionError.timedOut
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                throw ControlSocketConnectionError.closed
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
            }
            receiveBuffer.append(contentsOf: bytes.prefix(count))
            if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let frameSize = receiveBuffer.distance(from: receiveBuffer.startIndex, to: newline) + 1
                if frameSize > Self.maxFrameBytes {
                    throw ControlSocketConnectionError.frameTooLarge(size: frameSize)
                }
            } else if receiveBuffer.count > Self.maxFrameBytes {
                throw ControlSocketConnectionError.frameTooLarge(size: receiveBuffer.count)
            }
        }
    }

    public func close() async {
        if let fd {
            Darwin.close(fd)
            self.fd = nil
        }
    }

    private func writeAll(_ data: Data) throws {
        guard let fd else {
            throw ControlSocketConnectionError.closed
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
                }
                sent += count
            }
        }
    }

    private func waitForReadable(fd: Int32, timeout: TimeInterval) -> Bool {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32((timeout * 1000).rounded())
        let result = Darwin.poll(&pollFD, 1, timeoutMs)
        return result > 0
    }
}

private func bindUnixSocket(fd: Int32, path: String) throws {
    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address.sockaddr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, address.length)
        }
    }
    guard result == 0 else {
        throw ControlSocketServerError.bindFailed(path: path, errno: errno)
    }
}

private func connectUnixSocket(fd: Int32, path: String) throws {
    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address.sockaddr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, address.length)
        }
    }
    guard result == 0 else {
        throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
    }
}

private func unixAddress(path: String) throws -> (sockaddr: sockaddr_un, length: socklen_t) {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
        throw ControlSocketConnectError.other(underlying: "socket path too long")
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + pathBytes.count + 1)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        for (index, byte) in pathBytes.enumerated() {
            bytes[index] = byte
        }
        bytes[pathBytes.count] = 0
    }
    return (address, socklen_t(address.sun_len))
}
