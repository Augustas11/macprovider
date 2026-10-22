import Foundation
import MacProviderCore

// Issue #2084 the head's standby link to its spare (SPEC-051-R007, R015, R022). While
// the group serves, the head keeps one link open to the spare at the spare's epoch:
// its heartbeats measure the head-to-spare round trip the group heartbeat reports,
// its liveness is the spare's health, and when the downstream stage is lost the
// engine takes this already authenticated link for the takeover instead of dialing.
// A dedicated thread keeps the link up, so the engine thread never blocks on it.

/// The spare as the head sees it.
struct ShardGroupSpareHealth: Sendable, Equatable {
    let memberDeviceID: String
    /// `interface_type` the spare reported for its link to the head; nil before the
    /// first standby exchange.
    var interfaceType: String?
    var roundTrip: ShardLinkRoundTrip?
    /// The standby link is up and the spare was heard within the liveness window.
    var alive: Bool
}

final class ShardSpareStandby: @unchecked Sendable {
    /// Pause between attempts to bring the standby link up.
    static var retryInterval: TimeInterval { 1 }

    private let endpoint: ShardBenchEndpoint
    private let configuration: ShardLinkConfiguration
    private let signer: ShardMemberSigner
    private let headHello: ShardBenchHello
    /// The member the group config names as the spare (nil in the lab harness),
    /// and the layers it must hold: those of the stage it replaces.
    private let expectedMemberID: String?
    private let layers: Range<Int>
    private let modelDigest: String?
    private let handshakeTimeout: TimeInterval

    private enum Mode {
        case running
        /// A takeover is waiting for an attempt in progress to finish.
        case taking
        case stopped
    }

    /// How long a takeover waits for a standby attempt already in progress.
    static var takeWait: TimeInterval { 2 }

    private let lock = NSCondition()
    private var link: ShardStageLink?
    private var spareHello: ShardBenchHello?
    private var mode = Mode.running
    private var establishing = false
    private var lastFailure: String?
    private let wake = DispatchSemaphore(value: 0)

    /// `configuration` carries the spare's epoch (the one after the group's).
    init(
        endpoint: ShardBenchEndpoint, configuration: ShardLinkConfiguration, signer: ShardMemberSigner, headHello: ShardBenchHello,
        expectedMemberID: String?, layers: Range<Int>, modelDigest: String?, handshakeTimeout: TimeInterval
    ) {
        self.endpoint = endpoint
        self.configuration = configuration
        self.signer = signer
        self.headHello = headHello
        self.expectedMemberID = expectedMemberID
        self.layers = layers
        self.modelDigest = modelDigest
        self.handshakeTimeout = handshakeTimeout
    }

    func start() {
        let thread = Thread { [self] in maintain() }
        thread.name = "shard-spare-standby"
        thread.start()
    }

    /// Stop maintaining and close the standby link.
    func stop() {
        lock.lock()
        mode = .stopped
        let current = link
        link = nil
        lock.unlock()
        current?.close()
        wake.signal()
    }

    /// Hand the live standby link to the takeover and stop maintaining; nil when the
    /// link is not up (the caller dials the spare instead). An attempt in progress
    /// is waited for, briefly, so a spare that is just answering is not abandoned.
    func take() -> ShardStageLink? {
        lock.lock()
        guard mode == .running else {
            lock.unlock()
            return nil
        }
        mode = .taking
        let deadline = Date().addingTimeInterval(Self.takeWait)
        while establishing, lock.wait(until: deadline) {}
        mode = .stopped
        let current = link
        link = nil
        lock.unlock()
        wake.signal()
        guard let current, isAlive(current) else {
            current?.close()
            return nil
        }
        return current
    }

    var health: ShardGroupSpareHealth {
        lock.lock()
        let current = link
        let hello = spareHello
        lock.unlock()
        return ShardGroupSpareHealth(
            memberDeviceID: hello?.memberDeviceID ?? expectedMemberID ?? "", interfaceType: hello?.upstreamInterface,
            roundTrip: current?.roundTrip, alive: current.map(isAlive) ?? false)
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastFailure
    }

    private func isAlive(_ link: ShardStageLink) -> Bool {
        let window = configuration.heartbeatInterval * Double(max(1, configuration.missedHeartbeatLimit))
        return !link.hasFailed && link.secondsSinceLastByte <= window
    }

    private func maintain() {
        while true {
            lock.lock()
            guard mode == .running else {
                lock.unlock()
                return
            }
            let current = link
            let needed = current.map { !isAlive($0) } ?? true
            if needed {
                link = nil
                establishing = true
            }
            lock.unlock()
            if needed {
                current?.close()
                var established: ShardStageLink?
                do {
                    let (up, hello) = try establish()
                    established = up
                    lock.lock()
                    spareHello = hello
                    lastFailure = nil
                    lock.unlock()
                    shardGroupLog("standby link to spare \(hello.memberDeviceID ?? "unnamed") at \(up.peerAddress) is up")
                } catch {
                    lock.lock()
                    let first = lastFailure == nil
                    lastFailure = "\(error)"
                    lock.unlock()
                    if first { shardGroupLog("standby link to the spare at \(endpoint.host):\(endpoint.port) is down: \(error)") }
                }
                lock.lock()
                establishing = false
                // A takeover waiting on this attempt gets the link; a stop closes it.
                if mode == .stopped {
                    established?.close()
                } else {
                    link = established
                }
                lock.broadcast()
                lock.unlock()
            }
            _ = wake.wait(timeout: .now() + Self.retryInterval)
        }
    }

    /// Dial, authenticate, and exchange standby hellos: the spare answers with the
    /// chain through itself, which must name the configured spare and model.
    private func establish() throws -> (ShardStageLink, ShardBenchHello) {
        let link = try ShardStageLink.connect(
            host: endpoint.host, port: endpoint.port, timeout: min(2, handshakeTimeout), configuration: configuration)
        do {
            try link.authenticate(signer: signer, role: .initiator, timeout: handshakeTimeout)
            try ShardChainWire.sendHello(
                link, [headHello],
                header: ShardStageFrameHeader(
                    kind: .hello, groupEpoch: configuration.groupEpoch, sourceStage: 0, destinationStage: 1,
                    layerStart: UInt32(headHello.layerStart), layerEnd: UInt32(headHello.layerEnd)),
                standby: true)
            let reply = try ShardChainWire.awaitChainHello(
                link, timeout: handshakeTimeout, stageIndex: 0, layers: headHello.layerStart..<headHello.layerEnd)
            guard reply.standby == true, reply.stages.count == 2, reply.stages[0] == headHello else {
                throw ShardBenchError.handshake("the spare did not answer the standby hello with the chain through itself")
            }
            try ShardBenchChain.validateComplete(reply.stages)
            let spare = reply.stages[1]
            guard expectedMemberID == nil || spare.memberDeviceID == expectedMemberID,
                  spare.layerStart == layers.lowerBound, spare.layerEnd == layers.upperBound
            else {
                throw ShardBenchError.handshake("the spare is \(spare.memberDeviceID ?? "unnamed") \(spare.layerLabel), the group names \(expectedMemberID ?? "a spare") \(layers.lowerBound):\(layers.upperBound)")
            }
            if let modelDigest, spare.modelDigest != modelDigest {
                throw ShardBenchError.handshake("the spare's model digest \(spare.modelDigest ?? "none") differs from the head's \(modelDigest)")
            }
            guard spare.memberPublicKey != nil else { throw ShardBenchError.handshake("the spare announced no member key") }
            try ShardChainWire.checkPeer(link, is: spare, stage: 1)
            link.armLiveness()
            return (link, spare)
        } catch {
            link.close()
            throw error
        }
    }
}
