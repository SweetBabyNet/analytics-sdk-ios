import Foundation

/// 页面浏览追踪：
/// trackPage 调用时记录进入；离开该页（下一次 trackPage 或退后台）时补发 page_view，
/// duration_ms 为停留时长，refer_page 为上一页面；停留 <100ms 不上报。
/// 线程约束：所有方法必须在 AnalyticsCore 的串行队列上调用。
final class PageTracker {
    static let minDurationMs = 100

    var onPageView: ((_ page: String, _ referPage: String?, _ durationMs: Int, _ props: [String: Any]) -> Void)?

    private var currentPage: String?
    private var currentProps: [String: Any] = [:]
    private var referPage: String?
    private var enterTime: Date?

    var hasCurrentPage: Bool { currentPage != nil }
    var currentPageName: String? { currentPage }

    func enter(_ page: String, props: [String: Any]) {
        let leaving = currentPage
        leaveCurrent()
        referPage = leaving
        currentPage = page
        currentProps = props
        enterTime = Date()
    }

    /// 结束当前页（退后台时调用），不上报则静默丢弃
    func leaveCurrent() {
        guard let page = currentPage, let enter = enterTime else {
            reset()
            return
        }
        let durationMs = Int(Date().timeIntervalSince(enter) * 1000)
        let props = currentProps
        let refer = referPage
        reset()
        if durationMs >= PageTracker.minDurationMs {
            onPageView?(page, refer, durationMs, props)
        }
    }

    private func reset() {
        currentPage = nil
        currentProps = [:]
        enterTime = nil
    }
}
