#if DEBUG || MACPROVIDER_LAB_HARNESS
import CryptoKit
import Foundation
import MacProviderCore

/// Offline LAB input, never an assertion that the LAB executable is a signed CLI.
/// Uses the production signature, catalog/feed qualification and admission parser.
enum NativeMTPJourneySignedInputs {
    static func load(directory: URL, artifactRoot: URL, modelID: String,
                     target: MLXSnapshotIdentity, machine: MachineFingerprint,
                     slots: Int, preflightMetallibSHA256: String? = nil) throws -> NativeMTPHardwareSignedAdmission {
        guard StaticFeedOrigin.labOverride == nil else {
            throw NativeMTPHardwareE2EError.assertionFailed("signed journey inputs forbid static-feed lab trust overrides")
        }
        func read(_ name: String, limit: Int) throws -> Data {
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= limit else {
                throw NativeMTPHardwareE2EError.assertionFailed("invalid bounded signed journey input: \(name)")
            }
            let data = try Data(contentsOf: url)
            guard data.count == size else {
                throw NativeMTPHardwareE2EError.assertionFailed("signed journey input changed while reading")
            }
            return data
        }
        func signed(_ name: String) throws -> (Data, String) {
            let data = try read(name, limit: 16 * 1024 * 1024)
            let signature = try read(name + ".sig", limit: 16 * 1024)
            guard AutotuneStaticInputs.defaultSignatureVerifier(jsonBytes: data, sidecarBytes: signature),
                  let object = try JSONSerialization.jsonObject(with: signature) as? [String: Any],
                  let key = object["key_id"] as? String else {
                throw NativeMTPHardwareE2EError.assertionFailed("signed journey input signature rejected: \(name)")
            }
            return (data, key)
        }
        let (catalogBytes, catalogSigner) = try signed("catalog.json")
        let (feedBytes, feedSigner) = try signed("artifact-feed.json")
        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(catalogBytes)
        let feed = try AutotuneStaticInputs.qualifyArtifactFeed(
            feed: AutotuneStaticInputs.decodeArtifactFeed(feedBytes), bytes: feedBytes,
            signerKeyID: feedSigner, manifestSignerKeyID: feedSigner,
            catalog: catalog, candidateBytes: catalogBytes, candidateSignerKeyID: catalogSigner)
        let identities = feed.artifactIdentities().filter {
            $0.catalogKey == modelID && $0.isPrimary && $0.hash == target.digest
                && $0.hashAlgorithm == NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm
                && $0.verificationStatus == "verified"
        }
        guard identities.count == 1, let identity = identities.first else {
            throw NativeMTPHardwareE2EError.assertionFailed("signed feed has no unique verified target")
        }
        let authority = try feed.nativeMTPResolvedArtifactAuthority(
            releaseID: feed.releaseID, modelKey: modelID, artifactID: identity.artifactID,
            hash: target.digest, preflightTargetURL: artifactRoot.appendingPathComponent("target"))
        let sidecar = try read("native-mtp-admission.json", limit: NativeMTPAdmissionSidecar.maxSidecarBytes)
        let signature = try read("native-mtp-admission.json.sig", limit: NativeMTPAdmissionSidecar.maxSignatureBytes)
        let keyring = NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: AutotuneStaticInputs.defaultTrustedPublicKeys, requiredKeyID: feedSigner)
        let capability = try NativeMTPAdmissionSidecar.load(
            sidecarData: sidecar, signatureData: signature, snapshotRoot: directory,
            artifactRoot: artifactRoot,
            context: NativeMTPAdmissionSidecar.RuntimeContext(
                modelID: modelID, modelRevision: target.digest,
                upstreamMLXSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
                hardwareChip: machine.chip, ramGB: machine.ramGB, osVersion: machine.osVersion,
                slotCount: slots, revokedTupleSHA256: [], decodePathDigest: DecodePathIdentity.digest,
                metallibSHA256: preflightMetallibSHA256 ?? ModelRuntime.nativeMTPRuntimeMetallibSHA256()),
            trustedKeyring: keyring, resolvedArtifactAuthority: authority)
        guard capability.qualifiedSlots == slots else {
            throw NativeMTPHardwareE2EError.assertionFailed("signed journey slot tuple mismatch")
        }
        return NativeMTPHardwareSignedAdmission(capability: capability, sidecarData: sidecar,
            signatureData: signature, trustedKeyring: keyring, resolvedArtifactAuthority: authority)
    }
}
#endif
