#if DEBUG || MACPROVIDER_LAB_HARNESS
import CryptoKit
import Foundation
import MacProviderCore

/// Private, model-free request preregistration. It never contains completions.
/// Every actual factory call must match a production-parsed frozen body and
/// conversation-cache key; generated server identifiers are not parser inputs.
final class NativeMTPJourneyRequestInventory {
    static let schema = "macprovider.native-mtp-journey-requests.v1"
    private(set) var rows: [[String: Any]] = []
    private let recording: Bool
    let digest: String?
    init() { recording = true; digest = nil }
    init(data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw Self.invalid() }
        try AutotuneStrictJSON.rejectDuplicateKeys(data)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["schema", "requests"], value["schema"] as? String == Self.schema,
              let rows = value["requests"] as? [[String: Any]], !rows.isEmpty, rows.count <= 256 else { throw Self.invalid() }
        var seen = Set<Data>()
        for row in rows {
            guard seen.insert(try Self.canonical(row)).inserted, Set(row.keys) == ["id", "body_base64", "conversation_key"],
                  let id = row["id"] as? String, !id.isEmpty,
                  let encoded = row["body_base64"] as? String, let body = Data(base64Encoded: encoded),
                  row["conversation_key"] is String || row["conversation_key"] is NSNull else { throw Self.invalid() }
            _ = try ChatCompletionRequest.parse(data: body)
        }
        self.rows = rows
        recording = false
        digest = Self.sha(data)
    }
    func check(id: String, body: Data, conversationKey: String?) throws {
        _ = try ChatCompletionRequest.parse(data: body)
        let row: [String: Any] = ["id": id, "body_base64": body.base64EncodedString(),
                                  "conversation_key": conversationKey.map { $0 as Any } ?? NSNull()]
        let bytes = try Self.canonical(row)
        if recording { if !rows.contains(where: { (try? Self.canonical($0)) == bytes }) { rows.append(row) }; return }
        guard rows.contains(where: { (try? Self.canonical($0)) == bytes }) else { throw Self.invalid() }
    }
    func checkControl(id: String, conversationKey: String?) throws {
        guard let original = rows.first(where: { $0["id"] as? String == id }),
              let encoded = original["body_base64"] as? String, let body = Data(base64Encoded: encoded) else { throw Self.invalid() }
        try check(id: id + "-control", body: body, conversationKey: conversationKey.map { $0 + "-control" })
    }
    func data() throws -> Data { try Self.canonical(["schema": Self.schema, "requests": rows]) }
    static func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid() -> NativeMTPHardwareE2EError { .assertionFailed("journey request differs from immutable production-parsed inventory") }
}
#endif
