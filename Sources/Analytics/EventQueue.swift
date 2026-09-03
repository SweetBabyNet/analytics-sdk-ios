import Foundation

// MARK: - AnyCodable

/// 最小化的 Any Codable 包装，用于业务自定义 props（[String: Any]）。
/// 非 JSON 安全类型的值会被降级为字符串描述，保证序列化不抛异常。
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int64.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let a = try? container.decode([AnyCodable].self) {
            value = a.map { $0.value }
        } else if let o = try? container.decode([String: AnyCodable].self) {
            value = o.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let i as Int64:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let a as [Any]:
            try container.encode(a.map(AnyCodable.init))
        case let o as [String: Any]:
            try container.encode(o.mapValues(AnyCodable.init))
        default:
            try container.encode(String(describing: value))
        }
    }
}

// MARK: - AnalyticsEvent

/// 单条事件结构，字段与规范第 2 节 snake_case 完全一致。
/// 注意：属性名刻意使用 snake_case，配合 JSONEncoder 默认策略，
/// 避免 convertToSnakeCase 误伤 props 内的业务 key。
struct AnalyticsEvent: Codable {
    let event_id: String
    let event_name: String
    let event_type: String
    let event_time: Int64
    var duration_ms: Int?
    var page: String?
    var refer_page: String?
    var props: [String: AnyCodable]?

    let device_id: String
    var user_id: Int64?
    let session_id: String
    let is_new: Int

    let platform: String
    let app_version: String
    var build_number: String?
    var channel: String?
    var lang: String?

    var os_version: String?
    var device_brand: String?
    var device_model: String?
    var network: String?
    var screen_width: Int?
    var screen_height: Int?
}

// MARK: - 字段长度截断（以 sql/analytics.sql DDL 为唯一准绳）

enum FieldLimit {
    static let eventId = 40
    static let eventName = 64
    static let eventType = 16
    static let deviceId = 40
    static let sessionId = 40
    static let platform = 16
    static let appVersion = 16
    static let buildNumber = 16
    static let channel = 32
    static let lang = 16
    static let osVersion = 32
    static let deviceBrand = 32
    static let deviceModel = 64
    static let network = 8
    static let page = 64
    static let referPage = 64
    /// 崩溃 reason 截断长度（规范第 3 节）
    static let crashReason = 200
}

func truncated(_ s: String, _ limit: Int) -> String {
    s.count <= limit ? s : String(s.prefix(limit))
}

func truncatedOrNil(_ s: String?, _ limit: Int) -> String? {
    guard let s = s else { return nil }
    return truncated(s, limit)
}

// MARK: - EventQueue

/// 内存队列 + JSONL 文件兜底（Application Support/analytics/events.log）。
/// 上限 5000 条，超出丢最旧；启动时读回。
/// 线程约束：所有方法必须在 AnalyticsCore 的串行队列上调用。
final class EventQueue {
    static let maxCount = 5000

    private(set) var events: [AnalyticsEvent] = []
    let fileURL: URL

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var count: Int { events.count }

    init(directory: URL? = nil) {
        let dir = directory ?? EventQueue.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("events.log")
        loadFromFile()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("analytics", isDirectory: true)
    }

    // MARK: 读写

    private func loadFromFile() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        var loaded: [AnalyticsEvent] = []
        for var line in data.split(separator: UInt8(ascii: "\n")) {
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            guard !line.isEmpty, let event = try? decoder.decode(AnalyticsEvent.self, from: line) else { continue }
            loaded.append(event)
        }
        if loaded.count > EventQueue.maxCount {
            loaded = Array(loaded.suffix(EventQueue.maxCount))
            events = loaded
            rewriteFile()
        } else {
            events = loaded
        }
    }

    func append(_ event: AnalyticsEvent) {
        events.append(event)
        if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) {
            appendLine(line + "\n")
        }
        if events.count > EventQueue.maxCount {
            events = Array(events.suffix(EventQueue.maxCount))
            rewriteFile()
        }
    }

    func peek(_ limit: Int) -> [AnalyticsEvent] {
        Array(events.prefix(limit))
    }

    func removeFirst(_ n: Int) {
        guard n > 0 else { return }
        events.removeFirst(min(n, events.count))
        rewriteFile()
    }

    // MARK: 文件操作

    private func appendLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rewriteFile() {
        let lines = events.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
