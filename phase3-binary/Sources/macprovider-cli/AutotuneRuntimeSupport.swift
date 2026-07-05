import Darwin
import Dispatch
import Foundation

enum AutotuneCancellationReason: Equatable {
    case interrupted
    case budgetExhausted
}

final class AutotuneInterruptFlag {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class AutotuneSignalSources {
    private let sigintSource: DispatchSourceSignal
    private let sigtermSource: DispatchSourceSignal

    /// `cascadeToProcessGroup: true` — on SIGINT/SIGTERM the handler re-emits
    /// the signal to the current process group via `killpg(0, ...)`. Combined
    /// with a caller who has already made itself a process-group leader
    /// (`setpgid(0, 0)`), this forwards the shutdown signal to every child
    /// spawned during autotune (e.g. `CandidateProviderRunner` `serve
    /// --no-join` subprocesses). We remain immune because we've installed
    /// `SIG_IGN` for our own process before setting up dispatch sources.
    /// This closes the ARCH-M-1 orphan-child scenario on graceful App quit /
    /// runner-timeout paths: App calls `killpg(cliPid, SIGTERM)` → CLI cascades
    /// → all `serve --no-join` grandchildren die → CLI unwinds and exits.
    init(flag: AutotuneInterruptFlag, cascadeToProcessGroup: Bool = false) {
        let signalQueue = DispatchQueue(label: "autotune.signal")
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

        sigintSource.setEventHandler {
            flag.set()
            if cascadeToProcessGroup {
                _ = Darwin.killpg(0, SIGTERM)
            }
        }
        sigtermSource.setEventHandler {
            flag.set()
            if cascadeToProcessGroup {
                _ = Darwin.killpg(0, SIGTERM)
            }
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        sigintSource.resume()
        sigtermSource.resume()
    }

    deinit {
        sigintSource.cancel()
        sigtermSource.cancel()
    }
}

/// Make the current process a process-group leader so its `killpg`
/// semantics are self-contained: caller-of-CLI can now send signals to
/// the whole autotune subtree via `killpg(cliPid, SIGTERM)`.
///
/// Returns `true` on success. On failure (already a session leader,
/// permission), returns `false` — caller should log but proceed; the
/// orphan-child risk is unchanged from prior behavior.
@discardableResult
func autotuneBecomeProcessGroupLeader() -> Bool {
    return Darwin.setpgid(0, 0) == 0
}

struct MachineFingerprinter {
    func sample() -> MachineFingerprint {
        MachineFingerprint(
            ramGB: Self.ramGB(),
            chip: Self.sysctlString("machdep.cpu.brand_string") ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            binaryVersion: CoordinatorClient.binaryVersion
        )
    }

    private static func ramGB() -> Int {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let rc = sysctlbyname("hw.memsize", &memsize, &size, nil, 0)
        // Round-1 audit K.1 MINOR fix: return the documented minimum 1
        // (not 0) on sysctl failure or zero memsize. A zero ram_gb violates
        // the FR-G.2 schema "machine_ram_gb NOT NULL" intent (NULL would
        // be honest about the failure, 0 is impossible-machine which
        // poisons recipe_hash machine-sensitivity for fallback runs).
        guard rc == 0, memsize > 0 else {
            return 1
        }
        return max(1, Int((Double(memsize) / pow(1024.0, 3.0)).rounded()))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
