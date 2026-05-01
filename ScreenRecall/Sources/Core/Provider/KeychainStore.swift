import Foundation
import KeychainAccess

enum KeychainStore {
    private static let service = "com.anson.ScreenRecall"
    private static let chain = Keychain(service: service)

    enum Account: String {
        case tier1ApiKey = "tier1.apiKey"
        case tier2ApiKey = "tier2.apiKey"
    }

    static func get(_ account: Account) -> String? {
        let v = (try? chain.get(account.rawValue)) ?? nil
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    static func set(_ account: Account, _ value: String?) {
        do {
            if let value, !value.isEmpty {
                try chain.set(value, key: account.rawValue)
            } else {
                try chain.remove(account.rawValue)
            }
        } catch {
            AppLogger.settings.error("keychain set failed: \(error.localizedDescription)")
        }
    }
}
