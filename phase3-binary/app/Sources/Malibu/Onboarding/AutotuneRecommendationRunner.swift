import Foundation

enum AutotuneRecommendationRunner {
    private static let processTimeout: TimeInterval = 30

    private final class ProcessOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func value(appending remaining: Data) -> Data {
            lock.lock()
            var copy = data
            lock.unlock()
            copy.append(remaining)
            return copy
        }
    }

    static func run(
        cliURL: URL,
        configPath: URL = ProviderPaths.current.configFile
    ) async throws -> LaunchProviderController.ModelDownloadPlan {
        let data = try await runProcess(
            executableURL: cliURL,
            arguments: ["autotune", "--recommend", "--json", "--config", configPath.path]
        )
        return try LaunchProviderController.ModelDownloadPlan.fromAutotuneJSON(data)
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = processTimeout
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                let output = ProcessOutputBuffer()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    output.append(chunk)
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    _ = handle.availableData
                }

                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(max(1, timeout))
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                        throw AutotuneRecommendationError.timedOut
                    }
                    process.waitUntilExit()
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    let remainingOutput = stdout.fileHandleForReading.readDataToEndOfFile()
                    _ = stderr.fileHandleForReading.readDataToEndOfFile()
                    let data = output.value(appending: remainingOutput)
                    guard process.terminationStatus == 0 else {
                        throw AutotuneRecommendationError.nonZeroExit(process.terminationStatus)
                    }
                    continuation.resume(returning: data)
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum AutotuneRecommendationError: Error {
    case invalidJSON
    case nonZeroExit(Int32)
    case timedOut
}

extension LaunchProviderController.ModelDownloadPlan {
    static func fromAutotuneJSON(_ data: Data) throws -> Self {
        let rootObject = try JSONSerialization.jsonObject(with: data)
        guard let root = rootObject as? [String: Any] else {
            throw AutotuneRecommendationError.invalidJSON
        }

        let modelName = recommendedModel(in: root) ?? Self.recommended.modelName
        let range = earningsEstimate(modelName: modelName, root: root)
        return Self(modelName: modelName, state: nil, earningsEstimate: range)
    }

    private static func recommendedModel(in root: [String: Any]) -> String? {
        if let model = root["recommended_model"] as? String, !model.isEmpty {
            return model
        }
        if let recommendation = root["recommendation"] as? [String: Any],
           let model = recommendation["model"] as? String,
           !model.isEmpty {
            return model
        }
        return nil
    }

    private static func earningsEstimate(modelName: String, root: [String: Any]) -> EarningsEstimateRange? {
        if let explicit = explicitDailyRange(modelName: modelName, root: root) {
            return explicit
        }
        guard let candidate = candidate(modelName: modelName, root: root),
              let hourly = double(candidate["expected_net_usd_per_hour"]) else {
            return nil
        }
        let inputs = root["inputs"] as? [String: Any]
        let hours = double(inputs?["availability_hours_per_day"]) ?? 24
        let daily = max(0, hourly * hours)
        guard daily.isFinite else { return nil }
        return EarningsEstimateRange(lowDailyUSD: daily, highDailyUSD: daily)
    }

    private static func explicitDailyRange(modelName: String, root: [String: Any]) -> EarningsEstimateRange? {
        let candidate = candidate(modelName: modelName, root: root)
        let low = double(candidate?["expected_net_usd_per_day_low"])
            ?? double(root["expected_net_usd_per_day_low"])
            ?? double(root["estimated_daily_usd_low"])
        let high = double(candidate?["expected_net_usd_per_day_high"])
            ?? double(root["expected_net_usd_per_day_high"])
            ?? double(root["estimated_daily_usd_high"])
        guard let low, let high, low.isFinite, high.isFinite else { return nil }
        return EarningsEstimateRange(lowDailyUSD: max(0, min(low, high)), highDailyUSD: max(0, max(low, high)))
    }

    private static func candidate(modelName: String, root: [String: Any]) -> [String: Any]? {
        guard let candidates = root["candidates"] as? [[String: Any]] else { return nil }
        return candidates.first { ($0["model"] as? String) == modelName }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}
