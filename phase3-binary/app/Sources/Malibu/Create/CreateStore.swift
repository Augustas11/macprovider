import Foundation
import Combine

@MainActor
final class CreateStore: ObservableObject {
    @Published var prompt = ""
    @Published var size = "512x512"
    @Published var steps = 4
    @Published var seed = ""
    @Published private(set) var status: CreateStatus?
    @Published private(set) var images: [CreateImage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var notice: String?
    @Published private(set) var unavailableReason: String? = "Checking image generation availability…"
    private let transport: any CreateTransport
    private let gallery: CreateGallery
    private var task: Task<Void, Never>?
    private var endpoint: ChatEndpoint?

    init(transport: (any CreateTransport)? = nil, gallery: CreateGallery = CreateGallery()) {
        self.transport = transport ?? LocalCreateTransport(); self.gallery = gallery
        do { images = try gallery.load() }
        catch { notice = "The image gallery could not be opened. Check access to Pictures/Malibu." }
    }
    var canGenerate: Bool {
        unavailableReason == nil && status?.available == true && status?.phase.busy == false && !isRunning
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func refresh(port: Int?) async {
        do {
            guard let port else { throw CreateFailure.unavailable }
            let endpoint = try ChatEndpoint(port: port)
            let fresh = try await transport.status(at: endpoint)
            try Task.checkCancellation()
            self.endpoint = endpoint; status = fresh; unavailableReason = fresh.unavailableReason
            if !fresh.supportsLargeImages { size = "512x512" }
        } catch is CancellationError {
        } catch {
            status = nil; endpoint = nil
            unavailableReason = (error as? CreateFailure)?.localizedDescription ?? "The local provider is unavailable. Start the provider and try again."
        }
    }
    func generate() {
        guard canGenerate, let endpoint, let status else { return }
        do {
            let request = try CreateRequest(prompt: prompt, size: size, steps: steps, seed: seed, physicalMemory: status.physicalMemory)
            isRunning = true; notice = nil
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.isRunning = false; self.task = nil }
                do {
                    let data = try await self.transport.generate(at: endpoint, request: request)
                    try Task.checkCancellation()
                    let image = try self.gallery.save(data)
                    self.images.insert(image, at: 0)
                } catch is CancellationError {
                    self.notice = "Creation cancelled. Restoring customer work."
                } catch let error as URLError where error.code == .cancelled {
                    self.notice = "Creation cancelled. Restoring customer work."
                } catch {
                    self.notice = Self.creationFailureMessage(error)
                }
                await self.refresh(port: endpoint.port)
            }
        } catch { notice = error.localizedDescription }
    }
    func cancel() async {
        guard let endpoint else { task?.cancel(); return }
        do {
            try await transport.cancel(at: endpoint)
            task?.cancel()
            notice = "Creation cancelled. Restoring customer work."
        } catch { notice = "Cancellation could not be confirmed. Try Stop again." }
        await refresh(port: endpoint.port)
    }
    static func creationFailureMessage(_ error: Error) -> String {
        if let failure = error as? CreateFailure { return failure.localizedDescription }
        let detail = ShellText.display(error.localizedDescription)
        if let transport = error as? URLError {
            switch transport.code {
            case .timedOut:
                return "Image creation timed out while waiting for the local provider. \(detail)"
            case .networkConnectionLost:
                return "The connection to the local provider was lost. The provider may have restarted. \(detail)"
            case .cannotConnectToHost, .cannotFindHost:
                return "The local provider could not be reached. It may be restarting. \(detail)"
            default:
                return "Image creation could not connect to the local provider. \(detail)"
            }
        }
        return "The image could not be created or saved. \(detail)"
    }
    func waitForGeneration() async { await task?.value }
}
