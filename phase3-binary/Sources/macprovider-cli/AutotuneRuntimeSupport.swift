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

    init(flag: AutotuneInterruptFlag) {
        let signalQueue = DispatchQueue(label: "autotune.signal")
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

        sigintSource.setEventHandler {
            flag.set()
        }
        sigtermSource.setEventHandler {
            flag.set()
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
        guard rc == 0, memsize > 0 else {
            return 0
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
