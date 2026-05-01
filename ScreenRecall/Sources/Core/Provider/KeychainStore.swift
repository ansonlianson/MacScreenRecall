import Foundation
import KeychainAccess

enum KeychainStore {
    private static let service = "com.anson.ScreenRecall"
    private static let chain = Keychain(service: service)

    private static func account(forProfileId id: UUID) -> String {
        "model.\(id.uuidString)"
    }

    static func get(forProfileId id: UUID) -> String? {
        let v = (try? chain.get(account(forProfileId: id))) ?? nil
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    static func set(forProfileId id: UUID, value: String?) {
        do {
            if let value, !value.isEmpty {
                try chain.set(value, key: account(forProfileId: id))
            } else {
                try chain.remove(account(forProfileId: id))
            }
        } catch {
            AppLogger.settings.error("keychain set failed: \(error.localizedDescription)")
        }
    }

    static func delete(forProfileId id: UUID) {
        try? chain.remove(account(forProfileId: id))
    }
}
