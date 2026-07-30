import Foundation

struct EarningsEstimateRange: Equatable {
    let lowDailyUSD: Double
    let highDailyUSD: Double
}

enum ChipMarketingName {
    static func current(machine: () -> String? = hardwareModel) -> String {
        guard let model = machine(), !model.isEmpty else { return "your Mac" }
        return marketingName(for: model)
    }

    static func marketingName(for hardwareModel: String) -> String {
        if hardwareModel.localizedCaseInsensitiveContains("Mac15")
            || hardwareModel.localizedCaseInsensitiveContains("Mac16") {
            return "your M3 Mac"
        }
        if hardwareModel.localizedCaseInsensitiveContains("Mac14") {
            return "your M2 Mac"
        }
        if hardwareModel.localizedCaseInsensitiveContains("Mac13")
            || hardwareModel.localizedCaseInsensitiveContains("MacBookPro18")
            || hardwareModel.localizedCaseInsensitiveContains("MacBookAir10") {
            return "your M1 Mac"
        }
        return "your Mac"
    }

    private static func hardwareModel() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

enum EarningsEstimateFormatter {
    static func line(modelName: String, range: EarningsEstimateRange?, chipName: String = ChipMarketingName.current()) -> String? {
        guard let range else { return nil }
        return String(
            format: "%@ on %@ typically earns ~$%.2f-$%.2f/day at current demand.",
            displayModel(modelName),
            chipName,
            range.lowDailyUSD,
            range.highDailyUSD
        )
    }

    private static func displayModel(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: "-")
    }
}
