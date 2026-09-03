import Foundation

/// 崩溃捕获：包装原 NSSetUncaughtExceptionHandler，
/// 捕获后把 app_crash 事件直接追加到 JSONL 文件（不走内存队列），下次启动随队列上报。
///
/// 注意：仅捕获 NSException；信号类崩溃（SIGSEGV/SIGBUS 等）需要
/// PLCrashReporter 类库，本期不接（见 README）。
final class CrashReporter {
    static let shared = CrashReporter()

    private var previousHandler: NSUncaughtExceptionHandler?
    private var installed = false
    private let lock = NSLock()

    /// 事件 JSONL 文件路径（与 EventQueue 同一文件）
    private var fileURL: URL?
    /// 由 AnalyticsCore 提供：崩溃时刻的公共字段（device_id/session_id/platform 等）
    private var baseFieldsProvider: (() -> [String: Any])?
    /// 未 enable 时不落盘
    private var enabledProvider: (() -> Bool)?

    private init() {}

    func install(fileURL: URL,
                 baseFieldsProvider: @escaping () -> [String: Any],
                 enabledProvider: @escaping () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        self.fileURL = fileURL
        self.baseFieldsProvider = baseFieldsProvider
        self.enabledProvider = enabledProvider

        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.shared.handle(exception)
        }
    }

    private func handle(_ exception: NSException) {
        defer {
            // 交还原 handler（或让进程默认终止）
            if let previous = previousHandler {
                previous(exception)
            }
        }
        guard enabledProvider?() == true,
              let fileURL = fileURL,
              let base = baseFieldsProvider?() else { return }

        var event = base
        event["event_id"] = UUID().uuidString
        event["event_name"] = "app_crash"
        event["event_type"] = "error"
        event["event_time"] = Int64(Date().timeIntervalSince1970 * 1000)
        let reason = exception.reason ?? ""
        event["props"] = [
            "exception_name": exception.name.rawValue,
            "exception_reason": truncated(reason, FieldLimit.crashReason)
        ]

        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        // 直接追加文件，不走内存队列（崩溃现场尽量少的逻辑）
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL),
               let lineData = line.data(using: .utf8) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                try? handle.close()
            }
        } else {
            try? line.data(using: .utf8)?.write(to: fileURL)
        }
    }
}
