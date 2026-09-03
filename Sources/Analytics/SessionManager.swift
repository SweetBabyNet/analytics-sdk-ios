import Foundation

/// 会话管理：进入前台或新事件时若无活跃会话或距上一事件 >30 分钟，生成新会话。
/// 格式：s-yyyyMMdd-HHmmss-xxxx（xxxx 为 4 位随机十六进制）
final class SessionManager {
    static let sessionTimeout: TimeInterval = 30 * 60

    private let identity: IdentityStore

    init(identity: IdentityStore) {
        self.identity = identity
    }

    /// 返回当前会话 ID，必要时轮换；同时刷新最后事件时间。
    func touch(now: Date = Date()) -> String {
        let nowTs = now.timeIntervalSince1970
        let existing = identity.sessionId ?? ""
        let last = identity.lastEventTime
        if existing.isEmpty || last <= 0 || nowTs - last > SessionManager.sessionTimeout {
            let newSession = SessionManager.generate(now: now)
            identity.sessionId = newSession
            identity.lastEventTime = nowTs
            return newSession
        }
        identity.lastEventTime = nowTs
        return existing
    }

    static func generate(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let random = String(format: "%04x", Int.random(in: 0...0xFFFF))
        return "s-\(formatter.string(from: now))-\(random)"
    }
}
