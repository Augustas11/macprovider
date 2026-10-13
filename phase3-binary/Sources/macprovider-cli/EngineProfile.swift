import Foundation

/// SPEC-001-R006 closed `engine_profile` heartbeat object. A self-report the
/// coordinator uses as a routing prior only; it never carries measured
/// timings, which the coordinator takes from served traffic.
struct EngineProfile: Equatable {
    static let version = "engine-profile-v1"
    static let maximumCBGrantedSlots = 256
    static let maximumContextTokens = 10_000_000
    static let ramClassesGB = [8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 512]

    let engineFamily: String
    let cbGrantedSlots: Int
    let nativeMTPActive: Bool
    let chipClass: String
    let ramClassGB: Int
    let maxStableContextTokens: Int

    init(
        nativeMTPActive: Bool,
        continuousBatchingActive: Bool,
        cbGrantedSlots: Int,
        chip: String?,
        ramGB: Int,
        maxContextTokens: Int
    ) {
        self.nativeMTPActive = nativeMTPActive
        if nativeMTPActive {
            engineFamily = "native_mtp"
        } else if continuousBatchingActive {
            engineFamily = "continuous_batching"
        } else {
            engineFamily = "general_mlx"
        }
        self.cbGrantedSlots = continuousBatchingActive
            ? min(max(cbGrantedSlots, 0), Self.maximumCBGrantedSlots)
            : 0
        chipClass = Self.chipClass(chip)
        ramClassGB = Self.ramClass(ramGB)
        maxStableContextTokens = min(max(maxContextTokens, 0), Self.maximumContextTokens)
    }

    init(snapshot: RuntimeSnapshot, chip: String?, ramGB: Int, maxContextTokens: Int) {
        let cb = snapshot.continuousBatching
        let cbActive = cb?.active == true
        self.init(
            nativeMTPActive: snapshot.nativeMTPStatus.mode == .active,
            continuousBatchingActive: cbActive,
            cbGrantedSlots: cb?.scheduler?.slotsTotal ?? 0,
            chip: chip,
            ramGB: ramGB,
            maxContextTokens: maxContextTokens
        )
    }

    var wireObject: [String: Any] {
        [
            "version": Self.version,
            "engine_family": engineFamily,
            "cb_granted_slots": cbGrantedSlots,
            "native_mtp_active": nativeMTPActive,
            "chip_class": chipClass,
            "ram_class_gb": ramClassGB,
            "max_stable_context_tokens": maxStableContextTokens,
        ]
    }

    /// `mN`, `mN_pro`, `mN_max` or `mN_ultra` (N in 1..9) from a chip name
    /// such as "Apple M2 Max"; `unknown` for anything else.
    static func chipClass(_ chip: String?) -> String {
        guard let chip else { return "unknown" }
        let words = chip.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let index = words.firstIndex(where: { word in
            word.count == 2 && word.first == "m" && word.last.map { ("1"..."9").contains($0) } == true
        }) else {
            return "unknown"
        }
        let generation = words[index]
        guard index + 1 < words.count else { return generation }
        switch words[index + 1] {
        case "pro", "max", "ultra":
            return "\(generation)_\(words[index + 1])"
        default:
            return generation
        }
    }

    static func ramClass(_ ramGB: Int) -> Int {
        ramClassesGB.last(where: { $0 <= ramGB }) ?? ramClassesGB[0]
    }
}
