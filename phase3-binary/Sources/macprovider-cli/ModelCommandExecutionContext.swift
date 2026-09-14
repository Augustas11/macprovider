import Foundation
import MacProviderCore

/// Explicit command boundary dependencies. Shipping command entry points always
/// use production; fixture contexts are supplied directly by test code, never
/// selected through a CLI option, environment variable, or mutable global.
struct ModelCommandExecutionContext {
    // Compiled command fixtures may delay an actual read boundary. Shipping
    // entrypoints retain nil; no CLI option or environment variable selects it.
    var catalogReadHashProgress: ((UInt64) throws -> Void)? = nil
    static var production: Self { Self() }

    var inputs: () -> AutotuneStaticInputs = { AutotuneStaticInputs() }
    var configureTransactionRunner: (inout ModelCatalogTransactionRunner) -> Void = { _ in }
    var discoveryEnvironment: (BYOMDiscoveryEnvironment) -> BYOMDiscoveryEnvironment = { $0 }
    var providerStore: (AppConfig) -> any ProviderCredentialStoring = {
        ProviderCredentialStoreFactory.providerStore(for: $0)
    }
    var identityStore: (AppConfig) -> any ProviderIdentityKeyStoring = {
        ProviderCredentialStoreFactory.receiptKeyStore(for: $0)
    }
    var admissionClient: (String) throws -> BYOMModelAdmissionClient = {
        try BYOMModelAdmissionClient(coordinatorURL: $0)
    }
    var adoptionHardware: () -> MachineFingerprint = { MachineFingerprinter().sample() }
    var adoptionJournalRoot: URL = RecommendationAdoptionJournalStore.defaultRoot
    var projectionHome: URL? = nil
    var projectionEnvironment: [String: String] = ProcessInfo.processInfo.environment
}
