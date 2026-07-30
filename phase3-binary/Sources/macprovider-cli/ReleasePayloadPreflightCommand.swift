import ArgumentParser
import Foundation

struct ReleasePayloadPreflightCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-payload-preflight",
        abstract: "Validate the adjacent signed compatibility release payload.",
        shouldDisplay: false
    )

    func run() throws {
        guard let executableURL = CompatibilitySetManifest.resolvedExecutableURL(
            Bundle.main.executableURL
        ) else {
            throw ValidationError("release payload preflight cannot resolve its executable")
        }
        let payloadDirectory = executableURL.deletingLastPathComponent()
        try ProviderReleasePayloadTransaction.validateReleasePayload(
            at: payloadDirectory,
            newBinary: executableURL
        )
        let manifest = try CompatibilitySetManifest.loadValidated(
            from: payloadDirectory,
            expectedProviderVersion: CoordinatorClient.binaryVersion
        )
        var output = try JSONSerialization.data(withJSONObject: [
            "compatibility_set_id": manifest.compatibilitySetID,
            "status": "valid",
            "version": manifest.version,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        output.append(0x0a)
        FileHandle.standardOutput.write(output)
    }
}
