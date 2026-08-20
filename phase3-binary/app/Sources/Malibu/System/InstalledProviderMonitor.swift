import Darwin
import Foundation

struct ProviderLifecycleEventSnapshot: Equatable {
    let sequence: Int64
    let transitionID: String
    let transitionAt: Date
    let state: String
    let reason: String
    let writer: String
    let compatibilitySetID: String?
    let operationID: String?
}

/// Observes a launchd-managed macprovider-cli via local HTTP /v1/health and /v1/status.
enum InstalledProviderMonitor {
    static let supportedContractReaderVersion = 1

    struct HealthSnapshot: Equatable {
        let ready: Bool
        let model: String?
        let requestsTotal: Int?
        let requestsToday: Int?
        let inputTokensToday: Int64?
        let outputTokensToday: Int64?
        let inputTokensAllTime: Int64?
        let outputTokensAllTime: Int64?
        let uptimeSeconds: Int?
        let restartCount: Int?
    }

    struct StatusSnapshot: Equatable {
        let binaryVersion: String?
        let compatibilitySetID: String?
        let compatibilitySetSHA256: String?
        let providerID: String?
        let contractVersion: Int?
        let minimumReaderVersion: Int?
        let contractCompatible: Bool?
        let lifecycleOwner: String?
        let capabilities: Set<String>
        let observationID: String?
        let observedAt: Date?
        let observationValidForMS: Int?
        let observationFresh: Bool?
        let serviceInstanceID: String?
        let servicePID: Int?
        let serviceBootSession: String?
        let serviceStartedAt: Date?
        let serviceRole: String?
        let transitionRecordState: String?
        let transitionSequence: Int64?
        let transitionID: String?
        let transitionAt: Date?
        let transitionState: String?
        let transitionReason: String?
        let transitionAuthority: String?
        let transitionWriter: String?
        let transitionOperationID: String?
        let operatorPaused: Bool?
        let lastRestart: ProviderLifecycleEventSnapshot?
        let lastRejection: ProviderLifecycleEventSnapshot?
        let lastUpdate: ProviderLifecycleEventSnapshot?
        let lastWatchdog: ProviderLifecycleEventSnapshot?
        let lifecycleLeaseState: String?
        let lifecycleLeaseKind: String?
        let lifecycleLeaseOperationID: String?
        let lifecycleLeaseExpiresWallMS: Int64?
        let recommendedVersion: String?
        let coordinatorConnected: Bool
        let coordinatorTier: String?
        let coordinatorIdentityAdmissionMode: String?
        let networkState: String?
        let advertisedMaxConcurrency: Int?
        let catalogState: String?
        let catalogReleaseID: String?
        let catalogDigest: String?
        let catalogSignerKeyID: String?
        let catalogSource: String?
        let credentialSource: String?
        let credentialState: String?
        let credentialRestartSafe: Bool?
        let credentialMigrationPending: Bool?
        let credentialRecoveryAction: String?
        let admissionIdentitySource: String?
        let admissionIdentityState: String?
        let admissionIdentityPublicKeySHA256: String?
        let admissionIdentityPendingPublicKeySHA256: String?
        let admissionIdentityPreviousPublicKeySHA256: String?
        let admissionIdentityPreviousValidUntil: Date?
        let admissionIdentityCoordinatorGeneration: Int?
        let admissionIdentityCoordinatorPublicKeySHA256: String?
        let admissionIdentityCoordinatorKeyRole: String?
        let admissionIdentityTransitionError: String?
        let admissionIdentityRecoveryAction: String?
    }

    static func readHTTPPort(paths: ProviderPaths = .current) -> Int? {
        ProviderConfig.readHTTPPort(paths: paths)
    }

    /// Resolve the installer-selected provider binary without trusting a
    /// launchd `program` line by itself. The installer manifest is an
    /// owner-only regular file and its path is constrained to this user's
    /// home, which also lets Malibu resume a custom path below the provider's
    /// validated install prefix. The manifest prefix is part of the schema so
    /// a stale/corrupt manifest cannot redirect repair into Documents, a
    /// project checkout, or another unrelated home-directory location.
    static func configuredProviderProgram(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let fallback = homeDirectory.appendingPathComponent("macprovider/macprovider-cli").standardizedFileURL
        let manifestURL = homeDirectory.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        guard let data = readOwnerPrivateRegularFile(
            manifestURL,
            maxBytes: 64 * 1024,
            fileManager: fileManager
        ),
              let manifest = try? JSONDecoder().decode(InstallManifest.self, from: data),
              manifest.binaryPath.hasPrefix("/"),
              let installPrefix = manifest.installPrefix,
              installPrefix.hasPrefix("/") else {
            return fallback
        }
        let candidate = URL(fileURLWithPath: manifest.binaryPath).standardizedFileURL
        let prefix = URL(fileURLWithPath: installPrefix).standardizedFileURL
        guard candidate.lastPathComponent == "macprovider-cli",
              candidate.deletingLastPathComponent().path == prefix.path,
              isSupportedProviderInstallDirectory(prefix, under: homeDirectory) else {
            return fallback
        }
        guard isSafePrivateDirectoryChain(
            manifestURL.deletingLastPathComponent(),
            under: homeDirectory
        ), isSafePrivateDirectoryChainAllowingMissingLeaf(
            candidate.deletingLastPathComponent(),
            under: homeDirectory
        ) else {
            return fallback
        }
        return candidate
    }

    static let providerLaunchdLabel = "live.malibu.provider"
    static let watchdogLaunchdLabel = "live.malibu.provider-watchdog"
    static let legacyProviderLaunchdLabel = "live.streamvc.macprovider"
    static let legacyWatchdogLaunchdLabel = "live.streamvc.macprovider-watchdog"

    static func launchdServicePID(
        uid: uid_t = getuid(),
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) -> Int? {
        for label in [providerLaunchdLabel, legacyProviderLaunchdLabel] {
            guard let inspection = inspectLaunchdService(
                uid: uid,
                label: label,
                launchctlURL: launchctlURL
            ),
                  inspection.loaded,
                  let pid = parseLaunchdServicePID(inspection.output) else {
                continue
            }
            return pid
        }
        return nil
    }

    enum LaunchdServiceRepairState: Equatable {
        case unavailable
        case notLoaded
        case validExecutable
        case legacyExecutable(path: String)
        case missingExecutable(path: String)
        case unexpectedExecutable(path: String)
        case unexpectedPlist(path: String)

        var needsRepair: Bool {
            switch self {
            case .legacyExecutable, .missingExecutable:
                return true
            case .unavailable, .notLoaded, .validExecutable, .unexpectedExecutable, .unexpectedPlist:
                return false
            }
        }

        var requiresManualIntervention: Bool {
            switch self {
            case .unexpectedExecutable, .unexpectedPlist:
                return true
            case .unavailable, .notLoaded, .validExecutable, .legacyExecutable, .missingExecutable:
                return false
            }
        }
    }

    /// A readable plist is not enough to attach Malibu to a loaded job. Legacy
    /// standalone executables are repairable stale ownership, while unknown
    /// executable/plist identities remain manual conflicts. An unloaded
    /// managed plist is still inspected so a stale binary cannot dead-end startup.
    static func launchdServiceRepairState(
        uid: uid_t = getuid(),
        label: String = providerLaunchdLabel,
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        expectedProgram: URL? = nil,
        alternateProgram: URL? = nil,
        expectedPlist: URL? = nil,
        fileManager: FileManager = .default
    ) -> LaunchdServiceRepairState {
        let legacyFallback: () -> LaunchdServiceRepairState? = {
            guard label == providerLaunchdLabel else { return nil }
            let legacyPlist = homeDirectory
                .appendingPathComponent("Library/LaunchAgents")
                .appendingPathComponent("\(legacyProviderLaunchdLabel).plist")
            let state = launchdServiceRepairState(
                uid: uid,
                label: legacyProviderLaunchdLabel,
                launchctlURL: launchctlURL,
                homeDirectory: homeDirectory,
                expectedProgram: expectedProgram,
                alternateProgram: alternateProgram,
                expectedPlist: legacyPlist,
                fileManager: fileManager
            )
            switch state {
            case .unavailable, .notLoaded:
                return nil
            case .validExecutable, .legacyExecutable, .missingExecutable,
                 .unexpectedExecutable, .unexpectedPlist:
                return state
            }
        }
        guard let inspection = inspectLaunchdService(
            uid: uid,
            label: label,
            launchctlURL: launchctlURL
        ) else {
            return legacyFallback() ?? .unavailable
        }
        let managedProgram = (expectedProgram ?? configuredProviderProgram(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )).path
        let legacyProgram = (alternateProgram ?? homeDirectory.appendingPathComponent(".local/bin/macprovider-cli")).path
        let managedPlist = (expectedPlist ?? homeDirectory
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")).path
        if !inspection.loaded {
            guard isSafePrivateDirectoryChain(
                URL(fileURLWithPath: managedPlist).deletingLastPathComponent(),
                under: homeDirectory
            ), let plistData = readOwnerPrivateRegularFile(
                URL(fileURLWithPath: managedPlist),
                maxBytes: 64 * 1024,
                fileManager: fileManager
            ), let plistIdentity = parseLaunchdPlistIdentity(plistData),
                  plistIdentity.label == label else {
                return legacyFallback() ?? .notLoaded
            }
            guard plistIdentity.program == managedProgram || plistIdentity.program == legacyProgram else {
                return .unexpectedExecutable(path: plistIdentity.program)
            }
            guard isOwnerPrivateExecutable(atPath: plistIdentity.program) else {
                return .missingExecutable(path: plistIdentity.program)
            }
            if plistIdentity.program == legacyProgram {
                return .legacyExecutable(path: plistIdentity.program)
            }
            return legacyFallback() ?? .notLoaded
        }
        guard let identity = parseLaunchdServiceIdentity(inspection.output) else {
            return .unavailable
        }
        guard identity.path == managedPlist else {
            return .unexpectedPlist(path: identity.path)
        }
        // launchctl's textual identity is not sufficient evidence that the
        // on-disk plist is still the managed, owner-private file. Re-read the
        // expected path without following symlinks and bind its label/program
        // to the loaded job before considering repair.
        guard isSafePrivateDirectoryChain(
            URL(fileURLWithPath: managedPlist).deletingLastPathComponent(),
            under: homeDirectory
        ), let plistData = readOwnerPrivateRegularFile(
            URL(fileURLWithPath: managedPlist),
            maxBytes: 64 * 1024,
            fileManager: fileManager
        ), let plistIdentity = parseLaunchdPlistIdentity(plistData),
              plistIdentity.label == label,
              plistIdentity.program == identity.program else {
            return .unexpectedPlist(path: managedPlist)
        }
        guard identity.program == managedProgram || identity.program == legacyProgram else {
            return .unexpectedExecutable(path: identity.program)
        }
        guard isOwnerPrivateExecutable(atPath: identity.program) else {
            return .missingExecutable(path: identity.program)
        }
        if identity.program == legacyProgram {
            return .legacyExecutable(path: identity.program)
        }
        return .validExecutable
    }

    struct LaunchdServiceIdentity: Equatable {
        let program: String
        let path: String
    }

    private struct InstallManifest: Decodable {
        let binaryPath: String
        let installPrefix: String?

        enum CodingKeys: String, CodingKey {
            case binaryPath = "binary_path"
            case installPrefix = "install_prefix"
        }
    }

    private struct LaunchdPlistIdentity {
        let label: String
        let program: String
    }

    static func readOwnerPrivateRegularFile(
        _ url: URL,
        maxBytes: Int,
        fileManager: FileManager
    ) -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size >= 0,
              info.st_size <= off_t(maxBytes),
              hasNoExtendedACL(descriptor) else {
            return nil
        }
        let initialIdentity = info
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maxBytes))
        while data.count < Int(info.st_size) {
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
        guard data.count == Int(initialIdentity.st_size) else { return nil }

        var finalIdentity = stat()
        guard Darwin.fstat(descriptor, &finalIdentity) == 0,
              sameFileIdentity(initialIdentity, finalIdentity),
              hasNoExtendedACL(descriptor) else {
            return nil
        }
        var pathIdentity = stat()
        guard Darwin.lstat(url.path, &pathIdentity) == 0,
              sameFileIdentity(finalIdentity, pathIdentity) else {
            return nil
        }
        _ = fileManager // Keep the injected boundary explicit for callers/tests.
        return data
    }

    private static func parseLaunchdPlistIdentity(_ data: Data) -> LaunchdPlistIdentity? {
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let plist = object as? [String: Any],
              let label = plist["Label"] as? String,
              !label.isEmpty else {
            return nil
        }
        let program = (plist["Program"] as? String)
            ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, !program.isEmpty else { return nil }
        return LaunchdPlistIdentity(label: label, program: program)
    }

    static func isOwnerPrivateExecutable(atPath path: String) -> Bool {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_mode & S_IXUSR != 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              hasNoExtendedACL(descriptor) else {
            return false
        }
        return true
    }

    static func isSafePrivateDirectoryChain(_ directory: URL, under home: URL) -> Bool {
        let homePath = home.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath == homePath || directoryPath.hasPrefix(homePath + "/") else {
            return false
        }

        let relativePath = String(directoryPath.dropFirst(homePath.count))
        var current = URL(fileURLWithPath: homePath, isDirectory: true)
        guard isSafePrivateDirectory(atPath: current.path, homePath: homePath) else { return false }
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard isSafePrivateDirectory(atPath: current.path, homePath: homePath) else { return false }
        }
        return true
    }

    static func isSafePrivateDirectoryChainAllowingMissingLeaf(
        _ directory: URL,
        under home: URL
    ) -> Bool {
        let homePath = home.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath == homePath || directoryPath.hasPrefix(homePath + "/") else {
            return false
        }

        let relativePath = String(directoryPath.dropFirst(homePath.count))
        var current = URL(fileURLWithPath: homePath, isDirectory: true)
        guard isSafePrivateDirectory(atPath: current.path, homePath: homePath) else { return false }
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if isSafePrivateDirectory(atPath: current.path, homePath: homePath) {
                continue
            }
            var identity = stat()
            guard Darwin.lstat(current.path, &identity) != 0, errno == ENOENT else {
                return false
            }
            return true
        }
        return true
    }

    static func isSupportedProviderInstallDirectory(
        _ directory: URL,
        under home: URL
    ) -> Bool {
        let homePath = home.standardizedFileURL.path
        let rawComponents = directory.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            return false
        }
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath != homePath,
              directoryPath.hasPrefix(homePath + "/") else {
            return false
        }
        return isSafePrivateDirectoryChainAllowingMissingLeaf(directory, under: home)
    }

    private static func isSafePrivateDirectory(atPath path: String, homePath: String) -> Bool {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && info.st_nlink >= 1
            && info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return false
        }
        // $HOME may carry a write-style ACL that stranded the old watchdog
        // (`acl_write_rejected:$HOME`). The watchdog exception is exact-path
        // HOME only; descendants and evidence files stay strict. Matching that
        // here lets Malibu attach to a still-serving CLI and admit repair
        // instead of treating an admitted provider as a new join.
        if path == homePath {
            return true
        }
        // macOS commonly adds a deny-delete ACL to user directory ancestors
        // (including ~/Library). It does not grant write access, so
        // directory-chain trust remains based on the owner, no-follow, and
        // mode checks above. Files carrying authoritative launchd/configuration
        // data stay strict below.
        return hasSafeDirectoryACL(descriptor)
    }

    private static func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 else { return false }
        return entry == nil
    }

    private static func hasSafeDirectoryACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }

        guard let everyone = getgrnam("everyone") else { return false }
        var textLength: ssize_t = 0
        guard let text = acl_to_text(acl, &textLength) else { return false }
        defer { _ = acl_free(UnsafeMutableRawPointer(text)) }

        let lines = String(cString: text)
            .split(whereSeparator: \.isNewline)
        guard lines.count >= 2, lines[0] == "!#acl 1" else { return false }
        let everyoneGroupID = String(everyone.pointee.gr_gid)
        return lines.dropFirst().allSatisfy { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  fields[0] == "group",
                  UUID(uuidString: String(fields[1])) != nil,
                  fields[2] == "everyone",
                  fields[3] == everyoneGroupID,
                  fields[4] == "deny",
                  fields[5] == "delete" else {
                return false
            }
            return true
        }
    }

    static func parseLaunchdServiceIdentity(_ output: String) -> LaunchdServiceIdentity? {
        let programLines = output.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("program = ") else { return nil }
            let program = String(trimmed.dropFirst("program = ".count))
            return program.isEmpty ? nil : program
        }
        let pathLines = output.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("path = ") else { return nil }
            let path = String(trimmed.dropFirst("path = ".count))
            return path.isEmpty ? nil : path
        }
        guard programLines.count == 1, pathLines.count == 1 else { return nil }
        return LaunchdServiceIdentity(program: programLines[0], path: pathLines[0])
    }

    static func parseLaunchdServiceProgramPath(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("program = ") else { continue }
            let path = String(trimmed.dropFirst("program = ".count))
            return path.isEmpty ? nil : path
        }
        return nil
    }

    static func hasTrustedPrivateFile(
        at url: URL,
        maxBytes: Int = 64 * 1024,
        fileManager: FileManager = .default
    ) -> Bool {
        readOwnerPrivateRegularFile(url, maxBytes: maxBytes, fileManager: fileManager) != nil
    }

    private struct LaunchdServiceInspection {
        let loaded: Bool
        let output: String
    }

    private static func inspectLaunchdService(
        uid: uid_t,
        label: String,
        launchctlURL: URL
    ) -> LaunchdServiceInspection? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = launchctlURL
        process.arguments = ["print", "gui/\(uid)/\(label)"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readData(ofLength: 64 * 1024 + 1)
            if data.count > 64 * 1024 {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            process.waitUntilExit()
            return LaunchdServiceInspection(
                loaded: process.terminationStatus == 0,
                output: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return nil
        }
    }

    static func parseLaunchdServicePID(_ output: String) -> Int? {
        var parsedPID: Int?
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, fields[0] == "pid", fields[1] == "=",
                  let pid = Int(fields[2]), pid > 0 else {
                continue
            }
            guard parsedPID == nil else { return nil }
            parsedPID = pid
        }
        return parsedPID
    }

    static func serviceIdentityMatches(
        _ status: StatusSnapshot,
        expectedProviderID: String,
        launchdPID: Int?,
        liveCodeMatches: (pid_t) -> Bool
    ) -> Bool {
        guard status.providerID == expectedProviderID else { return false }
        guard status.capabilities.contains("service_instance_v1") else { return true }
        guard let servicePID = status.servicePID,
              servicePID > 0,
              servicePID == launchdPID,
              status.serviceRole == "serve" else {
            return false
        }
        return liveCodeMatches(pid_t(servicePID))
    }

    static func isHealthy(port: Int, timeout: TimeInterval = 2) async -> Bool {
        await fetchHealth(port: port, timeout: timeout)?.ready == true
    }

    static func fetchHealth(port: Int, timeout: TimeInterval = 2) async -> HealthSnapshot? {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/health")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let status = object["status"] as? String
            let model = object["model"] as? String
            let requestsTotal = object["requests_total"] as? Int
            let requestsToday = object["requests_today"] as? Int
            let inputTokensToday = int64Value(object["input_tokens_today"])
            let outputTokensToday = int64Value(object["output_tokens_today"])
            let inputTokensAllTime = int64Value(object["input_tokens_all_time"])
            let outputTokensAllTime = int64Value(object["output_tokens_all_time"])
            let uptimeSeconds = object["uptime_s"] as? Int
            let restartCount = object["restart_count"] as? Int
            return HealthSnapshot(
                ready: isHealthyStatus(status),
                model: model,
                requestsTotal: requestsTotal,
                requestsToday: requestsToday,
                inputTokensToday: inputTokensToday,
                outputTokensToday: outputTokensToday,
                inputTokensAllTime: inputTokensAllTime,
                outputTokensAllTime: outputTokensAllTime,
                uptimeSeconds: uptimeSeconds,
                restartCount: restartCount
            )
        } catch {
            return nil
        }
    }

    // /v1/status includes an authoritative coordinator readiness lookup and may
    // wait through one 1-second rate-limit window before answering.
    static func fetchStatus(port: Int, timeout: TimeInterval = 5) async -> StatusSnapshot? {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return decodeStatus(data)
        } catch {
            return nil
        }
    }

    static func decodeStatus(
        _ data: Data,
        now: Date = Date(),
        currentBootSession: String? = currentBootSessionUUID()
    ) -> StatusSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let coordinator = object["coordinator"] as? [String: Any] ?? [:]
        let catalog = object["catalog"] as? [String: Any] ?? [:]
        let credential = object["credential"] as? [String: Any] ?? [:]
        let admissionIdentity = object["admission_identity"] as? [String: Any] ?? [:]
        let contract = object["local_status_contract"] as? [String: Any] ?? [:]
        let observation = object["observation"] as? [String: Any] ?? [:]
        let serviceInstance = object["service_instance"] as? [String: Any] ?? [:]
        let lifecycle = object["lifecycle"] as? [String: Any] ?? [:]
        let lifecycleLease = object["lifecycle_lease"] as? [String: Any] ?? [:]
        let capacity = object["capacity"] as? [String: Any] ?? [:]
        let capabilities = Set((contract["capabilities"] as? [Any] ?? []).compactMap(stringValue))
        let contractVersion = intValue(contract["version"])
        let minimumReaderVersion = intValue(contract["minimum_reader_version"])
        let contractCompatible: Bool?
        if contractVersion == nil, minimumReaderVersion == nil {
            contractCompatible = nil
        } else if let contractVersion, let minimumReaderVersion {
            contractCompatible = contractVersion >= 1
                && minimumReaderVersion <= supportedContractReaderVersion
        } else {
            contractCompatible = false
        }
        let legacyContract = contractVersion == nil && minimumReaderVersion == nil
        let trustBuyerServing = legacyContract || capabilities.contains("buyer_serving_authority_v1")
        let trustCatalog = legacyContract || capabilities.contains("catalog_status_v1")
        let trustCredential = legacyContract || capabilities.contains("credential_status_v1")
        let trustAdmissionIdentity = capabilities.contains("admission_identity_v1")
        let trustObservation = capabilities.contains("status_observation_v1")
        let trustServiceInstance = capabilities.contains("service_instance_v1")
        let trustLifecycle = capabilities.contains("lifecycle_transition_v1")
        let trustPersistedLifecycle = capabilities.contains("persisted_lifecycle_state_v1")
        let trustLifecycleEvents = capabilities.contains("lifecycle_significant_events_v1")
        let trustLifecycleLease = capabilities.contains("lifecycle_lease_v1")
        let trustCompatibilitySet = capabilities.contains("compatibility_set_v1")
        let decodedObservationID = stringValue(observation["id"])
        let decodedObservedAt = dateValue(observation["observed_at"])
        let decodedObservationValidity = intValue(observation["valid_for_ms"])
        let observationFresh: Bool?
        if trustObservation {
            if let decodedObservationID,
               !decodedObservationID.isEmpty,
               let decodedObservedAt,
               let decodedObservationValidity,
               (1...60_000).contains(decodedObservationValidity) {
                observationFresh = decodedObservedAt <= now.addingTimeInterval(1)
                    && decodedObservedAt.addingTimeInterval(Double(decodedObservationValidity) / 1_000) >= now
            } else {
                observationFresh = false
            }
        } else {
            observationFresh = nil
        }
        let decodedServiceInstanceID = stringValue(serviceInstance["instance_id"])
        let decodedServicePID = intValue(serviceInstance["pid"])
        let decodedServiceBootSession = stringValue(serviceInstance["boot_session"])?.lowercased()
        let decodedServiceStartedAt = dateValue(serviceInstance["started_at"])
        let decodedServiceRole = stringValue(serviceInstance["role"])
        let serviceIdentityValid = !trustServiceInstance || (
            decodedServiceInstanceID?.isEmpty == false
                && (decodedServicePID ?? 0) > 0
                && decodedServiceBootSession != nil
                && decodedServiceBootSession == currentBootSession?.lowercased()
                && decodedServiceStartedAt != nil
                && decodedServiceRole == "serve"
        )
        let trustContractFields = contractCompatible != false
        let trustTypedFields = trustContractFields
            && observationFresh != false
            && serviceIdentityValid
        let decodedLifecycleRecordState = stringValue(lifecycle["record_state"])
        let decodedLifecycleSequence = int64Value(lifecycle["sequence"])
        let decodedLifecycleID = stringValue(lifecycle["transition_id"])
        let decodedLifecycleAt = dateValue(lifecycle["transition_at"])
        let decodedLifecycleState = stringValue(lifecycle["state"])
        let decodedLifecycleReason = stringValue(lifecycle["reason_code"])
        let decodedLifecycleAuthority = stringValue(lifecycle["authority"])
        let decodedLifecycleWriter = stringValue(lifecycle["writer"])
        let decodedLifecycleOperationID = stringValue(lifecycle["operation_id"])
        let decodedOperatorPaused = lifecycle["operator_paused"] as? Bool
        let rawLastRestart = lifecycle["last_restart"]
        let rawLastRejection = lifecycle["last_rejection"]
        let rawLastUpdate = lifecycle["last_update"]
        let rawLastWatchdog = lifecycle["last_watchdog"]
        let decodedLastRestart = decodeLifecycleEvent(rawLastRestart)
        let decodedLastRejection = decodeLifecycleEvent(rawLastRejection)
        let decodedLastUpdate = decodeLifecycleEvent(rawLastUpdate)
        let decodedLastWatchdog = decodeLifecycleEvent(rawLastWatchdog)
        let lifecycleEventsValid = !trustLifecycleEvents || [
            (rawLastRestart, decodedLastRestart),
            (rawLastRejection, decodedLastRejection),
            (rawLastUpdate, decodedLastUpdate),
            (rawLastWatchdog, decodedLastWatchdog),
        ].allSatisfy { raw, decoded in
            raw == nil || raw is NSNull || decoded != nil
        }
        let persistedLifecycleValid: Bool = {
            guard trustPersistedLifecycle else { return true }
            switch decodedLifecycleRecordState {
            case "valid":
                return decodedLifecycleSequence.map { $0 > 0 } == true
                    && decodedLifecycleID.flatMap(UUID.init(uuidString:)) != nil
                    && decodedLifecycleID == decodedLifecycleID?.lowercased()
                    && decodedLifecycleAt != nil
                    && Self.lifecycleStates.contains(decodedLifecycleState ?? "")
                    && decodedLifecycleReason?.isEmpty == false
                    && decodedLifecycleAuthority == "macprovider_cli"
                    && Self.lifecycleWriters.contains(decodedLifecycleWriter ?? "")
                    && decodedOperatorPaused != nil
            case "missing":
                return decodedLifecycleID == nil
                    && decodedLifecycleState == "failed"
                    && decodedLifecycleReason == "lifecycle_state_missing"
                    && decodedLifecycleAuthority == "macprovider_cli"
            case "invalid":
                return decodedLifecycleID == nil
                    && decodedLifecycleState == "failed"
                    && decodedLifecycleReason == "lifecycle_state_invalid"
                    && decodedLifecycleAuthority == "macprovider_cli"
            default:
                return false
            }
        }()
        let exposeLifecycle = trustTypedFields && trustLifecycle && persistedLifecycleValid && lifecycleEventsValid
        return StatusSnapshot(
            binaryVersion: stringValue(object["binary_version"]),
            compatibilitySetID: trustTypedFields && trustCompatibilitySet
                ? stringValue(object["compatibility_set_id"])
                : nil,
            compatibilitySetSHA256: trustTypedFields && trustCompatibilitySet
                ? stringValue(object["compatibility_set_sha256"])
                : nil,
            providerID: trustContractFields ? stringValue(object["provider_id"]) : nil,
            contractVersion: contractVersion,
            minimumReaderVersion: minimumReaderVersion,
            contractCompatible: contractCompatible,
            lifecycleOwner: trustContractFields ? stringValue(contract["lifecycle_owner"]) : nil,
            capabilities: trustContractFields ? capabilities : [],
            observationID: trustContractFields && trustObservation ? decodedObservationID : nil,
            observedAt: trustContractFields && trustObservation ? decodedObservedAt : nil,
            observationValidForMS: trustContractFields && trustObservation ? decodedObservationValidity : nil,
            observationFresh: trustContractFields ? observationFresh : nil,
            serviceInstanceID: trustTypedFields && trustServiceInstance ? decodedServiceInstanceID : nil,
            servicePID: trustTypedFields && trustServiceInstance ? decodedServicePID : nil,
            serviceBootSession: trustTypedFields && trustServiceInstance ? decodedServiceBootSession : nil,
            serviceStartedAt: trustTypedFields && trustServiceInstance ? decodedServiceStartedAt : nil,
            serviceRole: trustTypedFields && trustServiceInstance ? decodedServiceRole : nil,
            transitionRecordState: exposeLifecycle
                ? decodedLifecycleRecordState
                : (trustTypedFields && trustPersistedLifecycle ? "invalid" : nil),
            transitionSequence: exposeLifecycle ? decodedLifecycleSequence : nil,
            transitionID: exposeLifecycle ? decodedLifecycleID : nil,
            transitionAt: exposeLifecycle ? decodedLifecycleAt : nil,
            transitionState: exposeLifecycle ? decodedLifecycleState : (trustTypedFields && trustPersistedLifecycle ? "failed" : nil),
            transitionReason: exposeLifecycle ? decodedLifecycleReason : (trustTypedFields && trustPersistedLifecycle ? "lifecycle_contract_invalid" : nil),
            transitionAuthority: exposeLifecycle ? decodedLifecycleAuthority : nil,
            transitionWriter: exposeLifecycle ? decodedLifecycleWriter : nil,
            transitionOperationID: exposeLifecycle ? decodedLifecycleOperationID : nil,
            operatorPaused: exposeLifecycle ? decodedOperatorPaused : nil,
            lastRestart: exposeLifecycle && trustLifecycleEvents ? decodedLastRestart : nil,
            lastRejection: exposeLifecycle && trustLifecycleEvents ? decodedLastRejection : nil,
            lastUpdate: exposeLifecycle && trustLifecycleEvents ? decodedLastUpdate : nil,
            lastWatchdog: exposeLifecycle && trustLifecycleEvents ? decodedLastWatchdog : nil,
            lifecycleLeaseState: trustTypedFields && trustLifecycleLease ? stringValue(lifecycleLease["state"]) : nil,
            lifecycleLeaseKind: trustTypedFields && trustLifecycleLease ? stringValue(lifecycleLease["kind"]) : nil,
            lifecycleLeaseOperationID: trustTypedFields && trustLifecycleLease ? stringValue(lifecycleLease["operation_id"]) : nil,
            lifecycleLeaseExpiresWallMS: trustTypedFields && trustLifecycleLease ? int64Value(lifecycleLease["expires_wall_ms"]) : nil,
            recommendedVersion: trustTypedFields
                ? stringValue(coordinator["recommended_binary_version"])
                : nil,
            coordinatorConnected: trustTypedFields && (coordinator["connected"] as? Bool) == true,
            coordinatorTier: trustTypedFields ? stringValue(coordinator["tier"]) : nil,
            coordinatorIdentityAdmissionMode: trustTypedFields
                ? stringValue(coordinator["identity_admission_mode"])
                : nil,
            networkState: trustTypedFields && trustBuyerServing ? stringValue(object["network_state"]) : nil,
            advertisedMaxConcurrency: trustTypedFields ? intValue(capacity["max_concurrency"]) : nil,
            catalogState: trustTypedFields && trustCatalog ? stringValue(catalog["state"]) : nil,
            catalogReleaseID: trustTypedFields && trustCatalog ? stringValue(catalog["release_id"]) : nil,
            catalogDigest: trustTypedFields && trustCatalog ? stringValue(catalog["digest"]) : nil,
            catalogSignerKeyID: trustTypedFields && trustCatalog ? stringValue(catalog["signer_key_id"]) : nil,
            catalogSource: trustTypedFields && trustCatalog ? stringValue(catalog["source"]) : nil,
            credentialSource: trustTypedFields && trustCredential ? stringValue(credential["source"]) : nil,
            credentialState: trustTypedFields && trustCredential ? stringValue(credential["state"]) : nil,
            credentialRestartSafe: trustTypedFields && trustCredential ? credential["restart_safe"] as? Bool : nil,
            credentialMigrationPending: trustTypedFields && trustCredential ? credential["migration_pending"] as? Bool : nil,
            credentialRecoveryAction: trustTypedFields && trustCredential
                ? stringValue(credential["recovery_action"])
                : nil,
            admissionIdentitySource: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["source"])
                : nil,
            admissionIdentityState: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["state"])
                : nil,
            admissionIdentityPublicKeySHA256: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["public_key_sha256"])
                : nil,
            admissionIdentityPendingPublicKeySHA256: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["pending_public_key_sha256"])
                : nil,
            admissionIdentityPreviousPublicKeySHA256: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["previous_public_key_sha256"])
                : nil,
            admissionIdentityPreviousValidUntil: trustTypedFields && trustAdmissionIdentity
                ? dateValue(admissionIdentity["previous_valid_until"])
                : nil,
            admissionIdentityCoordinatorGeneration: trustTypedFields && trustAdmissionIdentity
                ? intValue(admissionIdentity["coordinator_generation"])
                : nil,
            admissionIdentityCoordinatorPublicKeySHA256: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["coordinator_public_key_sha256"])
                : nil,
            admissionIdentityCoordinatorKeyRole: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["coordinator_key_role"])
                : nil,
            admissionIdentityTransitionError: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["transition_error"])
                : nil,
            admissionIdentityRecoveryAction: trustTypedFields && trustAdmissionIdentity
                ? stringValue(admissionIdentity["recovery_action"])
                : nil
        )
    }

    private static let lifecycleStates: Set<String> = [
        "installing", "importing_credentials", "starting_provider", "validating_catalog", "loading_model",
        "locally_ready_connecting", "authentication_required", "keychain_unavailable",
        "identity_migration_required", "catalog_incompatible", "serving_buyers", "update_in_progress",
        "rollback_in_progress", "paused_by_operator", "watchdog_recovery", "network_offline",
        "coordinator_unavailable", "degraded_serving", "failed", "uninstalled",
    ]

    private static let lifecycleWriters: Set<String> = [
        "serve", "installer", "updater", "watchdog", "credentials", "operator_command",
    ]

    private static func decodeLifecycleEvent(_ value: Any?) -> ProviderLifecycleEventSnapshot? {
        guard let object = value as? [String: Any],
              let sequence = int64Value(object["sequence"]), sequence > 0,
              let transitionID = stringValue(object["transition_id"]),
              UUID(uuidString: transitionID) != nil,
              transitionID == transitionID.lowercased(),
              let transitionAt = dateValue(object["transition_at"]),
              let state = stringValue(object["state"]), lifecycleStates.contains(state),
              let reason = stringValue(object["reason_code"]),
              let writer = stringValue(object["writer"]), lifecycleWriters.contains(writer) else {
            return nil
        }
        return ProviderLifecycleEventSnapshot(
            sequence: sequence,
            transitionID: transitionID,
            transitionAt: transitionAt,
            state: state,
            reason: reason,
            writer: writer,
            compatibilitySetID: stringValue(object["compatibility_set_id"]),
            operationID: stringValue(object["operation_id"])
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "<null>" else { return nil }
        return text
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let value = stringValue(value) else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func currentBootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.lowercased()
    }

    static func isHealthyStatus(_ status: String?) -> Bool {
        status == "ready" || status == "busy"
    }

    /// Poll until health responds or deadline elapses.
    static func waitForHealthy(
        port: Int,
        deadline: Date,
        pollInterval: TimeInterval = 2
    ) async -> Bool {
        while Date() < deadline {
            if await isHealthy(port: port) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let sleep = min(pollInterval, remaining)
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
        }
        return false
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
