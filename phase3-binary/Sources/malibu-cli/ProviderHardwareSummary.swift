import Darwin
import Foundation

struct ProviderHardwareSummary {
    var chip: String
    var bandwidthGBPerSec: Int
    var networkPowerKW: Double
    var gpuCoresTotal: Int
    var cpuCoresTotal: Int

    static func liveWireObject() -> [String: Any]? {
        cached.wireObject()
    }

    private static let cached: ProviderHardwareSummary = {
        let fingerprint = MachineFingerprinter().sample()
        let chip = fingerprint.chip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cpuCores = sysctlInt("hw.physicalcpu") ?? max(1, ProcessInfo.processInfo.processorCount)
        return ProviderHardwareSummary(
            chip: chip,
            bandwidthGBPerSec: inferredBandwidthGBPerSec(chip: chip),
            networkPowerKW: inferredPowerKW(chip: chip),
            gpuCoresTotal: inferredGPUCores(chip: chip),
            cpuCoresTotal: cpuCores
        )
    }()

    private func wireObject() -> [String: Any]? {
        var object: [String: Any] = [:]
        if !chip.isEmpty && chip != "unknown" {
            object["chip"] = chip
        }
        if bandwidthGBPerSec > 0 {
            object["bandwidth_gb_per_s"] = bandwidthGBPerSec
        }
        if networkPowerKW > 0 {
            object["network_power_kw"] = networkPowerKW
        }
        if gpuCoresTotal > 0 {
            object["gpu_cores_total"] = gpuCoresTotal
        }
        if cpuCoresTotal > 0 {
            object["cpu_cores_total"] = cpuCoresTotal
        }
        return object.isEmpty ? nil : object
    }

    private static func inferredGPUCores(chip: String) -> Int {
        let normalized = chip.lowercased()
        guard normalized.contains("apple") || normalized.contains(" m") || normalized.hasPrefix("m") else {
            return 0
        }
        let generation = appleSiliconGeneration(normalized) ?? 0
        if normalized.contains("ultra") {
            return generation >= 3 ? 80 : 60
        }
        if normalized.contains("max") {
            return generation >= 3 ? 40 : 32
        }
        if normalized.contains("pro") {
            return generation >= 4 ? 20 : 19
        }
        return generation >= 1 ? 10 : 0
    }

    private static func inferredBandwidthGBPerSec(chip: String) -> Int {
        let normalized = chip.lowercased()
        let generation = appleSiliconGeneration(normalized) ?? 0
        if normalized.contains("ultra") {
            return generation >= 3 ? 819 : 800
        }
        if normalized.contains("max") {
            return generation >= 4 ? 546 : 400
        }
        if normalized.contains("pro") {
            if generation >= 4 {
                return 273
            }
            return generation >= 1 ? 200 : 0
        }
        if generation >= 4 {
            return 120
        }
        if generation >= 2 {
            return 100
        }
        return generation == 1 ? 68 : 0
    }

    private static func inferredPowerKW(chip: String) -> Double {
        let normalized = chip.lowercased()
        if normalized.contains("ultra") {
            return 0.120
        }
        if normalized.contains("max") {
            return 0.095
        }
        if normalized.contains("pro") {
            return 0.065
        }
        if appleSiliconGeneration(normalized) != nil {
            return 0.040
        }
        return 0
    }

    private static func appleSiliconGeneration(_ normalizedChip: String) -> Int? {
        guard let match = normalizedChip.range(of: #"m[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return Int(normalizedChip[match].dropFirst())
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else {
            return nil
        }
        return Int(value)
    }
}
