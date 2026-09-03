import Foundation

/// Flush 调度：前台定时器（默认 30s，debug 5s）+ 队列阈值（默认 50 条，debug 5 条）。
/// 退后台触发的 flush 与失败退避由 AnalyticsCore 直接管理。
/// 线程约束：所有方法必须在传入的串行队列上调用。
final class FlushScheduler {
    static let defaultInterval: TimeInterval = 30
    static let defaultThreshold = 50
    static let debugInterval: TimeInterval = 5
    static let debugThreshold = 5

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var debug = false

    var onFlush: (() -> Void)?

    var threshold: Int { debug ? FlushScheduler.debugThreshold : FlushScheduler.defaultThreshold }
    private var interval: TimeInterval { debug ? FlushScheduler.debugInterval : FlushScheduler.defaultInterval }

    init(queue: DispatchQueue, debug: Bool = false) {
        self.queue = queue
        self.debug = debug
    }

    func setDebug(_ debug: Bool) {
        guard self.debug != debug else { return }
        self.debug = debug
        if timer != nil {
            stop()
            start()
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.onFlush?()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 事件入队后调用，达到阈值立即触发 flush
    func eventEnqueued(totalCount: Int) {
        if totalCount >= threshold {
            onFlush?()
        }
    }
}
