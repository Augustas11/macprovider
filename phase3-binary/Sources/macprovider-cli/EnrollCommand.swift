import ArgumentParser
import Foundation
import MacProviderCore

// MARK: - Enroll command

struct EnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Enroll this Mac in the macprovider MDM for hardware attestation.",
        subcommands: [EnrollRunCommand.self, EnrollStatusCommand.self],
        defaultSubcommand: EnrollRunCommand.self
    )
}

// MARK: - enroll (default: request profile and open System Settings)

struct EnrollRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Request an enrollment profile from the coordinator and open System Settings."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Coordinator URL. Overrides coordinator_url in config.")
    var coordinator: String?

    @Flag(help: "Print profile path instead of opening System Settings (non-interactive / test mode).")
    var noOpen = false

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(coordinatorURL: coordinator, configPath: config))
        let runner = EnrollCommandRunner(
            config: resolved,
            openSystemSettings: !noOpen,
            checker: { coordinatorURL in checkMDMEnrollment(coordinatorURL: coordinatorURL) },
            serialReader: { macHardwareSerialNumber() }
        )
        try await runner.run()
    }
}

// MARK: - enroll status

struct EnrollStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print current MDM enrollment state."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Coordinator URL. Overrides coordinator_url in config.")
    var coordinator: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(coordinatorURL: coordinator, configPath: config))
        let state = checkMDMEnrollment(coordinatorURL: resolved.coordinatorURL)
        switch state {
        case .notEnrolled:
            print("mdm_enrollment: not_enrolled")
        case .enrolledMacprovider(let serverURL):
            print("mdm_enrollment: macprovider server=\(serverURL)")
        case .enrolledOtherMDM(let serverURL):
            print("mdm_enrollment: other_mdm server=\(serverURL)")
            FileHandle.standardError.write(Data(
                "warning: Mac is managed by a foreign MDM; macprovider enrollment is unavailable.\n".utf8
            ))
        case .checkFailed:
            print("mdm_enrollment: unknown (profiles check failed)")
        }
    }
}

// MARK: - Enroll errors

enum EnrollError: Error, CustomStringConvertible {
    case serialNumberUnavailable
    case coordinatorURLMissing
    case coordinatorURLInvalid(String)
    case coordinatorRequestFailed(String)
    case coordinatorHTTPError(Int, body: String)
    case profileWriteFailed(String)
    case managedByOtherMDM(serverURL: String)

    var description: String {
        switch self {
        case .serialNumberUnavailable:
            return "Could not read hardware serial number from ioreg."
        case .coordinatorURLMissing:
            return "coordinator_url is not set. Pass --coordinator or set it in config.yaml."
        case .coordinatorURLInvalid(let raw):
            return "Could not derive enroll endpoint from coordinator URL: \(raw)"
        case .coordinatorRequestFailed(let detail):
            return "Failed to reach coordinator: \(detail)"
        case .coordinatorHTTPError(let status, let body):
            return "Coordinator returned HTTP \(status): \(body)"
        case .profileWriteFailed(let detail):
            return "Failed to write enrollment profile: \(detail)"
        case .managedByOtherMDM(let serverURL):
            return "This Mac is already managed by another MDM (server: \(serverURL)). "
                + "macOS allows only one MDM enrollment per device. "
                + "Remove the existing profile in System Settings → General → Device Management, "
                + "then re-run `macprovider-cli enroll`."
        }
    }
}

// MARK: - Enrollment result

struct EnrollResult: Sendable {
    let serialNumber: String
    let profilePath: URL
    let alreadyEnrolled: Bool
}

// MARK: - Runner (injectable for testing)

struct EnrollCommandRunner: Sendable {
    let config: AppConfig
    let openSystemSettings: Bool
    let checker: @Sendable (String?) -> MDMEnrollmentState
    let serialReader: @Sendable () -> String?

    init(
        config: AppConfig,
        openSystemSettings: Bool = true,
        checker: @escaping @Sendable (String?) -> MDMEnrollmentState = { checkMDMEnrollment(coordinatorURL: $0) },
        serialReader: @escaping @Sendable () -> String? = { macHardwareSerialNumber() }
    ) {
        self.config = config
        self.openSystemSettings = openSystemSettings
        self.checker = checker
        self.serialReader = serialReader
    }

    func run() async throws {
        let coordinatorURL = config.coordinatorURL

        switch checker(coordinatorURL) {
        case .enrolledMacprovider(let serverURL):
            print("mdm_enrollment: already enrolled server=\(serverURL)")
            return
        case .enrolledOtherMDM(let serverURL):
            let err = EnrollError.managedByOtherMDM(serverURL: serverURL)
            FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
            throw ExitCode(1)
        case .notEnrolled, .checkFailed:
            break
        }

        guard let rawCoordinatorURL = coordinatorURL, !rawCoordinatorURL.isEmpty else {
            FileHandle.standardError.write(Data("error: \(EnrollError.coordinatorURLMissing.description)\n".utf8))
            throw ExitCode(2)
        }

        let baseURL = coordinatorHTTPBase(rawCoordinatorURL)
        guard let enrollURL = URL(string: "\(baseURL)/v1/enroll") else {
            let err = EnrollError.coordinatorURLInvalid(rawCoordinatorURL)
            FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
            throw ExitCode(2)
        }

        guard let serial = serialReader(), !serial.isEmpty else {
            let err = EnrollError.serialNumberUnavailable
            FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
            throw ExitCode(2)
        }

        print("Requesting enrollment profile for serial \(serial)…")

        var request = URLRequest(url: enrollURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ["serial_number": serial])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let err = EnrollError.coordinatorRequestFailed(error.localizedDescription)
            FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
            throw ExitCode(3)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            let err = EnrollError.coordinatorHTTPError(http.statusCode, body: body)
            FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
            throw ExitCode(3)
        }

        let profilePath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macprovider-enroll-\(serial).mobileconfig")
        do {
            try data.write(to: profilePath, options: .atomic)
        } catch {
            let err = EnrollError.profileWriteFailed(error.localizedDescription)
            FileHandle.standardError.write(Data("error: \(err.description)\n".utf8))
            throw ExitCode(3)
        }

        print("Profile saved: \(profilePath.path)")

        if openSystemSettings {
            openProfile(profilePath)
        }
    }

    private func openProfile(_ profilePath: URL) {
        // Register the profile with System Settings.
        let openProfile = Process()
        openProfile.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProfile.arguments = [profilePath.path]
        openProfile.standardOutput = FileHandle.nullDevice
        openProfile.standardError = FileHandle.nullDevice
        try? openProfile.run()
        openProfile.waitUntilExit()

        // Pause briefly so the profile registers before we surface the pane.
        Thread.sleep(forTimeInterval: 1.0)

        // Open System Settings → Profiles.
        let openSettings = Process()
        openSettings.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openSettings.arguments = [
            "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
        ]
        openSettings.standardOutput = FileHandle.nullDevice
        openSettings.standardError = FileHandle.nullDevice
        try? openSettings.run()
        openSettings.waitUntilExit()

        print("Install the profile shown in System Settings to complete enrollment.")
    }
}
