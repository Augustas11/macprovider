import Foundation

/// Wire payload for metrics_response (SPEC-025 §5.2 / Session C3).
public struct ControlMetricsSnapshot: Equatable, Sendable {
    public var earningsUsdc: Double?
    public var malibuAccrued: Double?
    public var providerEarnings: ProviderEarningsSummary?
    public var gpuC: Double?
    public var latencyP50Ms: Int?
    public var uptimeSec: Int = 0
    public var requestsServedToday: Int?
    public var requestsServedAllTime: Int?
    public var requestsPerMinute: Double?
    public var inputTokensToday: Int64?
    public var outputTokensToday: Int64?
    public var inputTokensAllTime: Int64?
    public var outputTokensAllTime: Int64?
    public var queueDepth: Int?

    public init(
        earningsUsdc: Double? = nil,
        malibuAccrued: Double? = nil,
        providerEarnings: ProviderEarningsSummary? = nil,
        gpuC: Double? = nil,
        latencyP50Ms: Int? = nil,
        uptimeSec: Int = 0,
        requestsServedToday: Int? = nil,
        requestsServedAllTime: Int? = nil,
        requestsPerMinute: Double? = nil,
        inputTokensToday: Int64? = nil,
        outputTokensToday: Int64? = nil,
        inputTokensAllTime: Int64? = nil,
        outputTokensAllTime: Int64? = nil,
        queueDepth: Int? = nil
    ) {
        self.earningsUsdc = earningsUsdc
        self.malibuAccrued = malibuAccrued
        self.providerEarnings = providerEarnings
        self.gpuC = gpuC
        self.latencyP50Ms = latencyP50Ms
        self.uptimeSec = uptimeSec
        self.requestsServedToday = requestsServedToday
        self.requestsServedAllTime = requestsServedAllTime
        self.requestsPerMinute = requestsPerMinute
        self.inputTokensToday = inputTokensToday
        self.outputTokensToday = outputTokensToday
        self.inputTokensAllTime = inputTokensAllTime
        self.outputTokensAllTime = outputTokensAllTime
        self.queueDepth = queueDepth
    }

    static func from(
        provider snapshot: ProviderSnapshot,
        providerEarnings: ProviderEarningsSummary?
    ) -> ControlMetricsSnapshot {
        let rpm: Double?
        if let tps = snapshot.throughputTPSSinceLast, tps > 0 {
            rpm = tps * 60
        } else {
            rpm = nil
        }
        return ControlMetricsSnapshot(
            earningsUsdc: providerEarnings?.usdcToday,
            malibuAccrued: providerEarnings?.malibuToday,
            providerEarnings: providerEarnings,
            gpuC: nil,
            latencyP50Ms: snapshot.avgLatencyMSSinceLast.map { Int($0.rounded()) },
            uptimeSec: snapshot.uptimeSeconds,
            requestsServedToday: snapshot.requestsToday,
            requestsServedAllTime: snapshot.requestsTotal,
            requestsPerMinute: rpm,
            inputTokensToday: snapshot.inputTokensToday,
            outputTokensToday: snapshot.outputTokensToday,
            inputTokensAllTime: snapshot.inputTokensAllTime,
            outputTokensAllTime: snapshot.outputTokensAllTime,
            queueDepth: snapshot.requestsQueued
        )
    }
}

enum ControlMetricsBuilder {
	static func build(
		providerStatus: ProviderStatus?,
		providerEarningsClient: ProviderEarningsClient?,
		malibuAccrualClient: MalibuAccrualClient?,
		providerWalletStatusClient: ProviderWalletStatusClient? = nil,
		providerToken: String?
	) async -> ControlMetricsSnapshot {
        guard let providerStatus else {
            return ControlMetricsSnapshot()
        }
        // CS-3: the control-socket metrics poll (Malibu.app UI cadence) must NOT
        // reset the since-last window. That window is owned by the coordinator
        // heartbeat (CoordinatorClient.sendHeartbeat), whose since-last deltas feed
        // autotune demand ranking and SPEC-023 payout-first scoring. Draining it
        // here — the two share one ProviderStatus instance — truncated the next
        // heartbeat's window to the post-poll sliver. Read without resetting.
        let snapshot = await providerStatus.snapshot(resetWindow: false)
		var earnings: ProviderEarningsSummary?
		var accrual: MalibuAccrualSummary?
		var walletStatus: ProviderWalletStatusSummary?
		var walletStatusSchemaFailed = false
		// A genuine reward-telemetry OUTAGE on the accrual or wallet-status
		// endpoint (5xx server error, transport failure, or schema/decode drift)
		// must be signalled so the app never softens it into calm "warming up".
		// A 4xx / unavailable / bad-URL is treated as endpoint-not-usable and
		// tolerated (an older coordinator may not serve it), matching the
		// pre-existing legacy tolerance.
		var rewardTelemetryFailed = false
		if let token = providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !token.isEmpty {
			if let providerEarningsClient {
				do {
					earnings = try await providerEarningsClient.fetch(bearerToken: token)
				} catch ProviderEarningsClientError.httpStatus(let code) where (500...599).contains(code) {
					rewardTelemetryFailed = true
				} catch ProviderEarningsClientError.httpStatus {
				} catch ProviderEarningsClientError.unavailable {
				} catch ProviderEarningsClientError.invalidCoordinatorURL {
				} catch {
					// Transport or schema/decode failure on the earnings endpoint is
					// a real telemetry outage, not a benign "no earnings yet". A bare
					// try? here let a 5xx look identical to an empty first-run frame,
					// so the presenter took the calm warming-up branch.
					rewardTelemetryFailed = true
				}
			}
			if let malibuAccrualClient {
				do {
					accrual = try await malibuAccrualClient.fetch(bearerToken: token)
				} catch MalibuAccrualClientError.httpStatus(let code) where (500...599).contains(code) {
					rewardTelemetryFailed = true
				} catch MalibuAccrualClientError.httpStatus {
				} catch MalibuAccrualClientError.unavailable {
				} catch MalibuAccrualClientError.invalidCoordinatorURL {
				} catch {
					// Transport or schema/decode failure: a real outage.
					rewardTelemetryFailed = true
				}
			}
			if let providerWalletStatusClient {
				do {
					walletStatus = try await providerWalletStatusClient.fetch(bearerToken: token)
				} catch ProviderWalletStatusClientError.httpStatus(let code) where (500...599).contains(code) {
					rewardTelemetryFailed = true
				} catch ProviderWalletStatusClientError.httpStatus {
				} catch ProviderWalletStatusClientError.unavailable {
				} catch ProviderWalletStatusClientError.invalidCoordinatorURL {
				} catch {
					walletStatusSchemaFailed = true
				}
			}
		}
		if let accrual {
			earnings = earnings?.merging(accrual: accrual) ?? .from(accrual: accrual)
		}
		if let walletStatus {
			earnings = earnings?.merging(walletStatus: walletStatus) ?? ProviderEarningsSummary.unavailableWalletStatus().merging(walletStatus: walletStatus)
		} else if walletStatusSchemaFailed || rewardTelemetryFailed {
			// A wallet-status (or earnings) subprojection failed. If we already
			// hold an authoritative, fresh MALIBU reward projection — from a
			// successful accrual fetch or a fresh /earnings frame — preserve it.
			// Wiping it via markingWalletStatusUnavailable() here hid REAL earned
			// rewards ("MALIBU rewards not available yet") just because a secondary
			// call 5xx'd. Only fail closed to the explicit unavailable frame when
			// there is no authoritative reward projection to preserve.
			if !(earnings?.malibuProjectionFresh ?? false) {
				earnings = earnings?.markingWalletStatusUnavailable() ?? .unavailableWalletStatus()
			}
		}
		return .from(
            provider: snapshot,
            providerEarnings: earnings
        )
    }
}

extension ControlSocketCodec {
    static func encodeMetrics(_ metrics: ControlMetricsSnapshot) throws -> Data {
        try encode(.metricsResponse(metrics))
    }
}
