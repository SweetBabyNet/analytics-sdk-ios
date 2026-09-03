import Foundation
import Security

/// 身份与状态持久化：
/// - device_id 存 Keychain（Service 固定 com.analytics.sdk.deviceid，卸载重装稳定）
/// - user_id / 当日 is_new 标记 / device_register 标记 / session 存 UserDefaults
final class IdentityStore {
    private static let keychainService = "com.analytics.sdk.deviceid"
    private static let keychainAccount = "device_id"

    private enum DefaultsKey {
        static let userId = "analytics.sdk.user_id"
        static let deviceRegisterSent = "analytics.sdk.device_register_sent"
        static let lastEventDate = "analytics.sdk.last_event_date" // yyyyMMdd，用于 is_new
        static let sessionId = "analytics.sdk.session_id"
        static let lastEventTime = "analytics.sdk.last_event_time" // 秒级时间戳
    }

    private let defaults = UserDefaults.standard

    // MARK: device_id（Keychain）

    private(set) lazy var deviceId: String = IdentityStore.loadOrCreateDeviceId()

    private static func loadOrCreateDeviceId() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        let newId = UUID().uuidString
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(newId.utf8)
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            // Keychain 不可用时进程内仍可用，只是不再持久化
        }
        return newId
    }

    // MARK: user_id

    var userId: Int64? {
        get { (defaults.object(forKey: DefaultsKey.userId) as? NSNumber)?.int64Value }
        set {
            if let v = newValue {
                defaults.set(NSNumber(value: v), forKey: DefaultsKey.userId)
            } else {
                defaults.removeObject(forKey: DefaultsKey.userId)
            }
        }
    }

    // MARK: device_register 标记

    var deviceRegisterSent: Bool {
        get { defaults.bool(forKey: DefaultsKey.deviceRegisterSent) }
        set { defaults.set(newValue, forKey: DefaultsKey.deviceRegisterSent) }
    }

    // MARK: is_new（当日首次事件为 1）

    /// 若今日尚无事件，返回 true 并记录今日；否则返回 false。
    func consumeIsNewToday(now: Date = Date()) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: now)
        if defaults.string(forKey: DefaultsKey.lastEventDate) == today {
            return false
        }
        defaults.set(today, forKey: DefaultsKey.lastEventDate)
        return true
    }

    // MARK: session

    var sessionId: String? {
        get { defaults.string(forKey: DefaultsKey.sessionId) }
        set { defaults.set(newValue, forKey: DefaultsKey.sessionId) }
    }

    var lastEventTime: TimeInterval {
        get { defaults.double(forKey: DefaultsKey.lastEventTime) }
        set { defaults.set(newValue, forKey: DefaultsKey.lastEventTime) }
    }
}
