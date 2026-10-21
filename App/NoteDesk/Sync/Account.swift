import Foundation
import Security
import NoteStationKit

/// Учётные данные — целиком в Keychain (пароль нужен для тихого перелогина
/// после истечения сессии; deviceID позволяет не вводить 2FA каждый раз).
struct Account: Codable, Equatable {
    var serverURL: URL
    var username: String
    var password: String
    var session: DSMSession?
}

enum Keychain {
    private static let service = "app.notedesk.account"
    private static let key = "default"

    static func load() -> Account? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    static func save(_ account: Account) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}
