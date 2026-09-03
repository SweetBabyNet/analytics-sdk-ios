import Foundation
import UIKit
import Network

/// 设备与公共字段采集。network 由 NWPathMonitor 异步维护，启动早期可能为 "unknown"。
final class DeviceInfo {
    let platform = "ios"
    let deviceBrand = "Apple"
    let appVersion: String
    let buildNumber: String
    let lang: String
    let osVersion: String
    let deviceModel: String

    private(set) var channel: String = "appstore"
    private(set) var network: String = "unknown"

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.analytics.sdk.network")

    init() {
        let bundle = Bundle.main
        appVersion = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        buildNumber = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        lang = Locale.preferredLanguages.first ?? Locale.current.identifier
        osVersion = UIDevice.current.systemVersion

        var systemInfo = utsname()
        uname(&systemInfo)
        deviceModel = withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else {
                self?.network = "none"
                return
            }
            if path.usesInterfaceType(.wifi) {
                self?.network = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                // 不做细粒度制式探测，cellular 统一报 "4g"
                self?.network = "4g"
            } else {
                self?.network = "unknown"
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    /// setup 传入渠道，空则回落 "appstore"
    func setChannel(_ channel: String) {
        let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channel = trimmed.isEmpty ? "appstore" : trimmed
    }

    /// 屏幕物理像素宽高，仅 device_register 使用
    static func screenSize() -> (width: Int, height: Int) {
        let work = { () -> (Int, Int) in
            let bounds = UIScreen.main.bounds
            let scale = UIScreen.main.scale
            return (Int(bounds.width * scale), Int(bounds.height * scale))
        }
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}
