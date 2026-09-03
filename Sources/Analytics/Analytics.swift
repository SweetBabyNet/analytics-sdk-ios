import Foundation
import UIKit

/// 埋点 SDK 对外门面。所有方法线程安全、静默失败，不向业务抛异常。
public enum Analytics {

    /// 初始化。enable=false 时仅初始化不采集，Analytics.enable() 后开始采集（含补发 device_register）。
    /// 自动注册 UIApplication 生命周期通知，业务零额外调用。
    public static func setup(appKey: String, appSecret: String, endpoint: String, enable: Bool = true, channel: String = "") {
        AnalyticsCore.shared.setup(appKey: appKey, appSecret: appSecret, endpoint: endpoint, enable: enable, channel: channel)
    }

    public static func enable() {
        AnalyticsCore.shared.setEnabled(true)
    }

    public static func disable() {
        AnalyticsCore.shared.setEnabled(false)
    }

    /// 自定义事件。eventType 仅允许 biz / interact / exposure，非法值按 biz 处理并打 debug 日志；
    /// durationMs 仅 exposure 等有时长语义的事件使用，写入事件的 duration_ms，其余传 nil。
    public static func track(_ eventName: String, props: [String: Any] = [:], eventType: String = "biz", durationMs: Int? = nil) {
        AnalyticsCore.shared.track(eventName, props: props, eventType: eventType, durationMs: durationMs)
    }

    /// 页面进入。离开该页时自动补发 page_view（含停留时长与 refer_page）
    public static func trackPage(_ pageName: String, props: [String: Any] = [:]) {
        AnalyticsCore.shared.trackPage(pageName, props: props)
    }

    /// 接口异常，由业务网络层钩子调用
    public static func trackApiError(_ apiPath: String, httpCode: Int, bizCode: Int? = nil) {
        AnalyticsCore.shared.trackApiError(apiPath, httpCode: httpCode, bizCode: bizCode)
    }

    /// 设置/清除用户 ID（持久化，杀进程重进仍在）
    public static func setUserId(_ userId: Int64?) {
        AnalyticsCore.shared.setUserId(userId)
    }

    /// 手动立即上报
    public static func flush() {
        AnalyticsCore.shared.flush()
    }

    /// 联调模式：打印事件日志，flush 阈值降为 5 条/5 秒
    public static func setDebug(_ debug: Bool) {
        AnalyticsCore.shared.setDebug(debug)
    }
}

// MARK: - 内部核心

final class AnalyticsCore {
    static let shared = AnalyticsCore()

    /// 全部内部状态只在此串行队列上读写
    let queue = DispatchQueue(label: "com.analytics.sdk.core", qos: .utility)

    private let identity = IdentityStore()
    private lazy var sessionManager = SessionManager(identity: identity)
    private lazy var deviceInfo = DeviceInfo()
    private lazy var pageTracker = PageTracker()

    private var eventQueue: EventQueue?
    private var uploader: Uploader?
    private var scheduler: FlushScheduler?

    private var configured = false
    private(set) var enabled = false
    private var debug = false

    // 生命周期状态
    private var setupTime: Date?
    private var appStartSent = false
    private var lastBackgroundTime: Date?
    private var isActive = false
    private var observers: [NSObjectProtocol] = []

    // 上报状态
    private var inFlight = false
    private var retryIndex = 0
    private var retryScheduled = false
    private let retryDelays: [TimeInterval] = [5, 15, 60, 300] // 5s→15s→60s→5min 封顶

    private init() {}

    // MARK: setup

    func setup(appKey: String, appSecret: String, endpoint: String, enable: Bool, channel: String) {
        queue.async {
            guard !self.configured else { return }
            var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            guard !appKey.isEmpty, let url = URL(string: base + "/v1/track/batch") else {
                return // 参数非法，静默忽略
            }
            self.configured = true
            self.setupTime = Date()

            self.deviceInfo.setChannel(channel)
            let eventQueue = EventQueue()
            self.eventQueue = eventQueue
            self.uploader = Uploader(config: Uploader.Config(appKey: appKey, appSecret: appSecret, url: url))

            let scheduler = FlushScheduler(queue: self.queue, debug: self.debug)
            scheduler.onFlush = { [weak self] in self?.flushNow() }
            self.scheduler = scheduler

            self.pageTracker.onPageView = { [weak self] page, refer, durationMs, props in
                self?.enqueue(name: "page_view", type: "page", props: props,
                              page: page, referPage: refer, durationMs: durationMs, screen: nil)
            }

            self.registerLifecycleObservers()

            CrashReporter.shared.install(
                fileURL: eventQueue.fileURL,
                baseFieldsProvider: { [weak self] in self?.crashBaseFields() ?? [:] },
                enabledProvider: { [weak self] in self?.enabled ?? false }
            )

            // 若 setup 时应用已处于 active（如异步初始化），补一次冷启动判定
            DispatchQueue.main.async {
                let active = UIApplication.shared.applicationState == .active
                self.queue.async {
                    if active { self.handleBecameActive() }
                }
            }

            self.setEnabledLocked(enable)
        }
    }

    // MARK: enable / disable

    func setEnabled(_ value: Bool) {
        queue.async { self.setEnabledLocked(value) }
    }

    private func setEnabledLocked(_ value: Bool) {
        guard configured else { return }
        if value {
            guard !enabled else { return }
            enabled = true
            scheduler?.start()
            sendDeviceRegisterIfNeeded()
            // 隐私同意后补发冷启动 app_start
            if isActive && !appStartSent {
                appStartSent = true
                sendAppStart(launchType: "cold", durationMs: setupDurationMs())
            }
            flushNow()
        } else {
            enabled = false
            scheduler?.stop()
        }
    }

    // MARK: 对外事件入口

    private static let allowedTrackEventTypes: Set<String> = ["biz", "interact", "exposure"]

    func track(_ eventName: String, props: [String: Any], eventType: String, durationMs: Int?) {
        queue.async {
            var type = eventType
            if !Self.allowedTrackEventTypes.contains(type) {
                self.log("invalid eventType '\(eventType)', fallback to 'biz'")
                type = "biz"
            }
            self.enqueue(name: eventName, type: type, props: props,
                         page: self.pageTracker.currentPageName, referPage: nil, durationMs: durationMs, screen: nil)
        }
    }

    func trackPage(_ pageName: String, props: [String: Any]) {
        queue.async {
            guard self.canCollect else { return }
            self.pageTracker.enter(pageName, props: props)
        }
    }

    func trackApiError(_ apiPath: String, httpCode: Int, bizCode: Int?) {
        queue.async {
            var props: [String: Any] = [
                "api_path": apiPath,
                "http_code": httpCode
            ]
            if let bizCode = bizCode { props["biz_code"] = bizCode }
            self.enqueue(name: "api_error", type: "error", props: props,
                         page: self.pageTracker.currentPageName, referPage: nil, durationMs: nil, screen: nil)
        }
    }

    func setUserId(_ userId: Int64?) {
        queue.async { self.identity.userId = userId }
    }

    func setDebug(_ debug: Bool) {
        queue.async {
            self.debug = debug
            self.scheduler?.setDebug(debug)
        }
    }

    // MARK: 生命周期

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        let observe = { (name: Notification.Name, handler: @escaping () -> Void) in
            let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                handler()
            }
            self.observers.append(token)
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in
            self?.queue.async { self?.handleBecameActive() }
        }
        observe(UIApplication.willResignActiveNotification) { [weak self] in
            self?.queue.async { self?.isActive = false }
        }
        observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.queue.async { self?.handleWillEnterForeground() }
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.queue.async { self?.handleDidEnterBackground() }
        }
        observe(UIApplication.didFinishLaunchingNotification) { [weak self] in
            // setup 早于通知发出时，用通知时间作为冷启动计时起点的下界
            self?.queue.async { /* 冷启动计时以 setup 为起点，此处仅保持监听 */ }
        }
    }

    private func handleBecameActive() {
        isActive = true
        guard canCollect else { return }
        if !appStartSent {
            appStartSent = true
            sendAppStart(launchType: "cold", durationMs: setupDurationMs())
        } else if let background = lastBackgroundTime, Date().timeIntervalSince(background) > 30 {
            sendAppStart(launchType: "hot", durationMs: nil)
        }
        lastBackgroundTime = nil
    }

    private func handleWillEnterForeground() {
        guard canCollect else { return }
        _ = sessionManager.touch() // 距上一事件 >30 分钟则轮换会话
    }

    private func handleDidEnterBackground() {
        isActive = false
        lastBackgroundTime = Date()
        guard canCollect else { return }
        pageTracker.leaveCurrent() // 离开当前页，补发 page_view
        enqueue(name: "app_end", type: "lifecycle", props: [:],
                page: nil, referPage: nil, durationMs: nil, screen: nil)
        flushNow() // 退后台立即 flush
    }

    // MARK: 内置事件

    private func sendDeviceRegisterIfNeeded() {
        guard !identity.deviceRegisterSent else { return }
        identity.deviceRegisterSent = true
        _ = identity.consumeIsNewToday() // 占掉当日 is_new
        let screen = DeviceInfo.screenSize()
        enqueue(name: "device_register", type: "lifecycle", props: [:],
                page: nil, referPage: nil, durationMs: nil,
                screen: screen, forceIsNew: 1)
    }

    private func sendAppStart(launchType: String, durationMs: Int?) {
        enqueue(name: "app_start", type: "lifecycle", props: ["launch_type": launchType],
                page: nil, referPage: nil, durationMs: durationMs, screen: nil)
    }

    private func setupDurationMs() -> Int? {
        guard let setupTime = setupTime else { return nil }
        return max(0, Int(Date().timeIntervalSince(setupTime) * 1000))
    }

    // MARK: 事件入队

    private var canCollect: Bool { configured && enabled }

    private func enqueue(name: String, type: String, props: [String: Any],
                         page: String?, referPage: String?, durationMs: Int?,
                         screen: (width: Int, height: Int)?, forceIsNew: Int? = nil) {
        guard canCollect, let eventQueue = eventQueue else { return }
        let isNew = forceIsNew ?? (identity.consumeIsNewToday() ? 1 : 0)
        let event = AnalyticsEvent(
            event_id: truncated(UUID().uuidString, FieldLimit.eventId),
            event_name: truncated(name, FieldLimit.eventName),
            event_type: truncated(type, FieldLimit.eventType),
            event_time: Int64(Date().timeIntervalSince1970 * 1000),
            duration_ms: durationMs,
            page: truncatedOrNil(page, FieldLimit.page),
            refer_page: truncatedOrNil(referPage, FieldLimit.referPage),
            props: sanitizeProps(props),
            device_id: truncated(identity.deviceId, FieldLimit.deviceId),
            user_id: identity.userId,
            session_id: truncated(sessionManager.touch(), FieldLimit.sessionId),
            is_new: isNew,
            platform: truncated(deviceInfo.platform, FieldLimit.platform),
            app_version: truncated(deviceInfo.appVersion, FieldLimit.appVersion),
            build_number: truncated(deviceInfo.buildNumber, FieldLimit.buildNumber),
            channel: truncated(deviceInfo.channel, FieldLimit.channel),
            lang: truncated(deviceInfo.lang, FieldLimit.lang),
            os_version: truncated(deviceInfo.osVersion, FieldLimit.osVersion),
            device_brand: truncated(deviceInfo.deviceBrand, FieldLimit.deviceBrand),
            device_model: truncated(deviceInfo.deviceModel, FieldLimit.deviceModel),
            network: truncated(deviceInfo.network, FieldLimit.network),
            screen_width: screen?.width,
            screen_height: screen?.height
        )
        eventQueue.append(event)
        log("enqueue \(event.event_name) props=\(props)")
        scheduler?.eventEnqueued(totalCount: eventQueue.count)
    }

    /// 过滤非 JSON 安全类型，保证 AnyCodable 序列化不失败
    private func sanitizeProps(_ props: [String: Any]) -> [String: AnyCodable]? {
        guard !props.isEmpty else { return nil }
        return props.mapValues { AnyCodable(sanitizeValue($0)) }
    }

    private func sanitizeValue(_ value: Any) -> Any {
        switch value {
        case is String, is NSNumber, is NSNull:
            return value
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeValue($0) }
        case let array as [Any]:
            return array.map { sanitizeValue($0) }
        default:
            return String(describing: value)
        }
    }

    // MARK: flush

    func flush() {
        queue.async { self.flushNow() }
    }

    private func flushNow() {
        guard configured, let uploader = uploader, let eventQueue = eventQueue else { return }
        guard !inFlight, !retryScheduled else { return }
        let batch = eventQueue.peek(100)
        guard !batch.isEmpty else { return }
        inFlight = true
        log("flush \(batch.count) events")
        uploader.upload(batch) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                self.inFlight = false
                switch result {
                case .success:
                    self.eventQueue?.removeFirst(batch.count)
                    self.retryIndex = 0
                    if (self.eventQueue?.count ?? 0) > 0 { self.flushNow() }
                case .discard(let httpCode):
                    self.log("drop batch, http \(httpCode)")
                    self.eventQueue?.removeFirst(batch.count)
                    self.retryIndex = 0
                    if (self.eventQueue?.count ?? 0) > 0 { self.flushNow() }
                case .retryable:
                    self.scheduleRetry()
                }
            }
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex = min(retryIndex + 1, retryDelays.count - 1)
        log("retry in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.retryScheduled = false
            self.flushNow()
        }
    }

    // MARK: 崩溃公共字段

    private func crashBaseFields() -> [String: Any] {
        let userIdValue: Any
        if let uid = identity.userId {
            userIdValue = NSNumber(value: uid)
        } else {
            userIdValue = NSNull()
        }
        return [
            "event_id": NSNull(),     // 崩溃时覆写
            "event_name": NSNull(),
            "event_type": NSNull(),
            "event_time": NSNull(),
            "duration_ms": NSNull(),
            "page": NSNull(),
            "refer_page": NSNull(),
            "props": NSNull(),        // 崩溃时覆写
            "device_id": truncated(identity.deviceId, FieldLimit.deviceId),
            "user_id": userIdValue,
            "session_id": truncated(sessionManager.touch(), FieldLimit.sessionId),
            "is_new": 0,
            "platform": truncated(deviceInfo.platform, FieldLimit.platform),
            "app_version": truncated(deviceInfo.appVersion, FieldLimit.appVersion),
            "build_number": truncated(deviceInfo.buildNumber, FieldLimit.buildNumber),
            "channel": truncated(deviceInfo.channel, FieldLimit.channel),
            "lang": truncated(deviceInfo.lang, FieldLimit.lang),
            "os_version": truncated(deviceInfo.osVersion, FieldLimit.osVersion),
            "device_brand": truncated(deviceInfo.deviceBrand, FieldLimit.deviceBrand),
            "device_model": truncated(deviceInfo.deviceModel, FieldLimit.deviceModel),
            "network": truncated(deviceInfo.network, FieldLimit.network),
            "screen_width": NSNull(),
            "screen_height": NSNull()
        ]
    }

    private func log(_ message: String) {
        if debug { print("[Analytics] \(message)") }
    }
}
