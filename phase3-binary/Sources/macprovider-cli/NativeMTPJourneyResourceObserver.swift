#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation

/// Faults are request-scoped, reduce capacity only, and never exist in release builds.
final class NativeMTPJourneyResourceObserver: @unchecked Sendable {
    struct Fault: Sendable {
        let requestID: String
        let afterGeneratedTokens: Int
        let capacityBytes: Int
    }
    struct Reservation: Sendable {
        let requestID: String
        let generatedTokens: Int
        let depth: Int
        let bytes: Int
        let reservedBefore: Int
        let capacity: Int
        let admitted: Bool
    }
    struct Terminal: Sendable {
        let requestID: String
        let status: String
        let errorCode: String?
        let emittedTokens: Int
        let hasRetainedCache: Bool
        let hasSerialCache: Bool
    }
    private let lock = NSLock()
    private var reservations: [Reservation] = []
    private var terminals: [Terminal] = []
    let fault: Fault?
    init(fault: Fault? = nil) { self.fault = fault }
    func capacity(requestID: String, generatedTokens: Int, realCapacity: Int) -> Int {
        guard let fault, fault.requestID == requestID,
              generatedTokens >= fault.afterGeneratedTokens else { return realCapacity }
        return min(realCapacity, max(0, fault.capacityBytes))
    }
    func record(_ reservation: Reservation) {
        lock.lock(); defer { lock.unlock() }; reservations.append(reservation)
    }
    func record(_ terminal: Terminal) {
        lock.lock(); defer { lock.unlock() }; terminals.append(terminal)
    }
    func reservationSnapshot() -> [Reservation] {
        lock.lock(); defer { lock.unlock() }; return reservations
    }
    func terminalSnapshot() -> [Terminal] {
        lock.lock(); defer { lock.unlock() }; return terminals
    }
}
#endif
