import Foundation
import Security

enum ConnectedBuyerKeychain {
    static let service = "tech.malibu.connected-apps"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "buyer"]
    }
    static func save(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ConnectedAppsError.credential
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = query.merging(attributes) { _, new in new }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw ConnectedAppsError.credential }
        } else if status != errSecSuccess { throw ConnectedAppsError.credential }
    }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ConnectedAppsError.credential
        }
        return key
    }
    /// Hands the key to one launcher run: a 0600 regular file in a 0700
    /// directory owned by this user, which the launcher reads once and
    /// deletes. Any stale handoff is replaced.
    static func writeLaunchHandoff(_ key: String, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else {
            throw ConnectedAppsError.credential
        }
        removeLaunchHandoff(file)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ConnectedAppsError.credential }
        let bytes = Data(key.utf8)
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let synced = fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0
        close(descriptor)
        guard written == bytes.count, synced else {
            removeLaunchHandoff(file)
            throw ConnectedAppsError.credential
        }
    }

    static func removeLaunchHandoff(_ file: URL) {
        _ = unlink(file.path)
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectedAppsError.credential }
    }
}
