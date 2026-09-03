# Analytics SDK (iOS)

iOS 埋点 SDK，Swift Package，零第三方依赖（仅 Foundation / UIKit / Network / Security / zlib / CommonCrypto）。
协议与行为遵守 `docs/埋点协议与SDK规范.md`，字段长度遵守 `sql/analytics.sql` DDL。

- 要求：iOS 13+，Swift 5.7+
- 上报：`POST {endpoint}/v1/track/batch`，gzip + `X-Sign`（HMAC-SHA256 hex，对最终传输字节计算）
- 缓冲：内存队列 + JSONL 文件兜底（Application Support/analytics/events.log，上限 5000 条丢最旧）
- flush：50 条 / 30 秒 / 退后台，每批 ≤100 条；失败退避 5s→15s→60s→5min；400/401 丢弃
- debug 模式：5 条 / 5 秒，打印事件日志

## SPM 集成

### 本地依赖

1. 把 `sdk-ios` 目录拷入工程（或放在仓库内任意位置）。
2. Xcode：File → Add Package Dependencies… → Add Local…，选择 `sdk-ios` 目录。
3. 在 App Target 的 Frameworks, Libraries, and Embedded Content 中添加 `Analytics` library。

### 远程依赖（GitHub，推荐）

本 SDK 托管在 GitHub，Swift Package 原生支持直接引用：

```
.package(url: "https://github.com/SweetBabyNet/analytics-sdk-ios.git", from: "1.0.0")
```

Xcode 中：File → Add Package Dependencies…，输入仓库 URL，版本规则 Up to Next Major `1.0.0`。
版本号即 git tag（如 `v1.0.1`），SDK 发版 = 打 tag 并推送。

## 使用

### App 入口 setup

UIKit AppDelegate：

```swift
import Analytics

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
    Analytics.setup(
        appKey: "cfood-help",
        appSecret: "YOUR_SECRET",
        endpoint: "https://analytics.example.com",
        enable: true,          // 或按隐私授权状态传 false，授权后调 Analytics.enable()
        channel: "appstore"
    )
    return true
}
```

SwiftUI App：在 `@main struct App.init()` 或 `.onAppear` 中调用一次即可
（SDK 只通过 `UIApplication` 通知感知生命周期，不依赖 UIKit 视图层，与 SwiftUI 宿主完全兼容）。

### 页面与事件

```swift
Analytics.trackPage("HomePage")                       // 进入页面；离开时自动补发 page_view
Analytics.track("add_to_favorite", props: ["baby_id": 88])
Analytics.trackApiError("/v1/baby/list", httpCode: 500, bizCode: 10001)
Analytics.setUserId(12345)                            // 登出时传 nil
Analytics.flush()                                     // 业务大动作后可选
```

### 两段式 enable（隐私合规）

```swift
// 启动时：未同意隐私政策
Analytics.setup(appKey: ..., appSecret: ..., endpoint: ..., enable: false)

// 用户同意后：
Analytics.enable()    // 开始采集，自动补发 device_register 与冷启动 app_start
```

## API 列表

| API | 说明 |
|---|---|
| `setup(appKey:appSecret:endpoint:enable:channel:)` | 初始化；`channel` 默认 `"appstore"`；自动注册生命周期通知 |
| `enable()` / `disable()` | 采集开关；`enable()` 含补发 device_register |
| `track(_:props:eventType:durationMs:)` | 自定义事件，props 为 `[String: Any]`；`eventType` 仅允许 `biz`/`interact`/`exposure`（默认 `biz`，非法值按 `biz` 处理并打 debug 日志）；`durationMs` 写入 `duration_ms`，仅 exposure 等有时长语义的事件使用 |
| `trackPage(_:props:)` | 页面进入；离开补发 page_view（duration/refer_page），停留 <100ms 不上报 |
| `trackApiError(_:httpCode:bizCode:)` | 接口异常，业务网络层钩子调一行 |
| `setUserId(_: Int64?)` | 设置/清除用户 ID，持久化 |
| `flush()` | 手动立即上报 |
| `setDebug(_:)` | 联调模式：日志 + 5 条/5 秒 flush |

内置自动事件：`device_register`（首启一次，带屏幕宽高）、`app_start`（冷/热启动，回前台距上次退出 >30s 算热启动）、`app_end`（退后台，立即 flush）、`app_crash`（见下）。

## 崩溃捕获说明

`CrashReporter` 通过 `NSSetUncaughtExceptionHandler` 包装原 handler，**仅捕获 NSException**
（如数组越界、unrecognized selector 等 ObjC 运行时异常）。捕获后将 `app_crash` 事件
（props 含 exception name + reason 前 200 字符）直接追加到 JSONL 文件，下次启动随队列上报。

**信号类崩溃（SIGSEGV / SIGBUS / SIGABRT 等）不在本期范围**，需要 PLCrashReporter
类库实现 async-signal-safe 捕获；如需完整崩溃覆盖请接入专业崩溃 SDK。

## 隐私合规

1. **两段式 enable**：务必在用户同意隐私政策前 `setup(..., enable: false)`，同意后 `Analytics.enable()`。
   enable 前 SDK 不采集、不上报任何数据。
2. **PrivacyInfo.xcprivacy**：SDK 本体不内置隐私清单文件。宿主 App 的隐私清单需申报：
   - `NSPrivacyCollectedDataTypes`：Device ID（`NSPrivacyCollectedDataTypeDeviceID`，用途 App Functionality/Analytics）、
     使用数据（Product Interaction）
   - `NSPrivacyAccessedAPITypes`：UserDefaults（`NSPrivacyAccessedAPICategoryUserDefaults`，
     reason `CA92.1` 或按实际用途选择）
3. **App Store 隐私标签**：需勾选 设备 ID、使用数据（分析用途，不关联身份则按实际勾选）。
4. **Keychain 使用说明**：device_id 存于 Keychain（Service `com.analytics.sdk.deviceid`，
   `kSecAttrAccessibleAfterFirstUnlock`），卸载重装保持稳定，不跨 App 共享。
   user_id / 会话等运行时状态存 UserDefaults。
