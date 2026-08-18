import AppKit
import OSLog
import Sparkle

/// Sparkle 2 自动更新封装（SwiftPM 引入的 binary framework；feed 托管在
/// GitHub Pages，DMG 发布在 GitHub Releases，见 Scripts/make-release.sh）。
///
/// 沙箱配置依据（Info.plist / entitlements 中的注释亦引用了原文）：
/// - `SUEnableInstallerLauncherService = YES`：Sparkle 沙箱文档
///   "The Installer XPC Service is required for Sandboxed applications."
/// - `com.apple.security.network.client`：更新检查是应用唯一的联网行为；
///   有了它即不启用 Downloader XPC（同文档："…you should not enable the
///   Downloader XPC Service."）。
/// - mach-lookup temporary exception（`-spks` / `-spki`）：同文档
///   "Communication" 一节，供 Sparkle 与其安装器工具通信。
///
/// 「自动检查」开关的唯一事实源是 `SettingsStore.autoUpdateCheckEnabled`：
/// start() 时一次性写入 SPUUpdater，运行期变更经 applySettings() 同步
/// （AppDelegate 的 UserDefaults.didChangeNotification 驱动，与
/// applyTriggerSettings 同机制）。Sparkle 会把该属性持久化到
/// SUEnableAutomaticChecks，因此无需再由我们回写。
@MainActor
@Observable
final class UpdateController: NSObject {
    /// 更新检查状态摘要（供日志与将来 UI 展示；更新提示 UI 由 Sparkle
    /// 标准 user driver 承担）。
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case error(String)
    }

    private(set) var status: Status = .idle

    private let settings: SettingsStore
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "Update")

    /// UpdateController 本身由 AppDelegate 懒加载，故 updater controller 可在
    /// init 直接创建。startingUpdater: false，由 start() 在应用完设置后显式启动。
    /// SPUUpdater 的 delegate 只能在初始化时传入（弱引用、无公开 setter），
    /// 故经 DelegateBridge 桥接——桥对象由 self 强持有，满足「调用方负责
    /// 保持 delegate 存活」的要求。
    private let updaterController: SPUStandardUpdaterController
    private let delegateBridge = DelegateBridge()
    private var didStart = false

    init(settings: SettingsStore) {
        self.settings = settings
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegateBridge,
            userDriverDelegate: nil
        )
        super.init()
        delegateBridge.owner = self
    }

    /// 菜单项可用性（Sparkle 建议用于验证 checkForUpdates 时机；KVO 属性，
    /// 这里只做瞬读，菜单项保持常启用——检查进行中 Sparkle 自己会忽略重复请求）。
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    /// 启动 updater（幂等）。无论「自动检查」开关与否都启动——手动
    /// 「检查更新…」同样需要已启动的 updater；开关只控制自动调度。
    /// start 前把设置一次性应用给 Sparkle（其 header 注释亦要求不要在每次
    /// 启动时覆盖用户偏好，这里写入的是我们自己设置页的唯一事实源，语义一致）。
    func start() {
        guard !didStart else { return }
        didStart = true
        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = settings.autoUpdateCheckEnabled
        do {
            try updater.start()
            logger.info("Sparkle updater started (automaticChecks: \(updater.automaticallyChecksForUpdates))")
        } catch {
            logger.error("Sparkle updater failed to start: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    /// 设置变更 → 同步 SUAutomaticallyChecksForUpdates。值相同则不写——
    /// 写会回写 UserDefaults 再次触发 didChange 通知，形成无谓循环
    /// （与 applyTriggerSettings 的幂等保护同理）。
    func applySettings() {
        guard didStart else { return }
        let updater = updaterController.updater
        if updater.automaticallyChecksForUpdates != settings.autoUpdateCheckEnabled {
            updater.automaticallyChecksForUpdates = settings.autoUpdateCheckEnabled
        }
    }

    /// 菜单「检查更新…」入口。自动检查关闭时也可手动触发。
    func checkForUpdates() {
        start()
        status = .checking
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Delegate callbacks (经 DelegateBridge 从主线程转发)

    fileprivate func noteUpdateNotFound() {
        status = .upToDate
    }

    /// Sparkle 的「无更新可用」也属于 abort 回调（SUSparkleErrorDomain /
    /// SUNoUpdateError = 1001，见 Sparkle/SUErrors.h）——这不是错误，
    /// 归入 upToDate（Sparkle 自己都不记这条日志，SPUUpdater.m:798）。
    private static func isNoUpdateError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue
    }

    fileprivate func noteUpdateAborted(_ error: any Error) {
        guard !Self.isNoUpdateError(error) else {
            status = .upToDate
            return
        }
        status = .error(error.localizedDescription)
        logger.error("Sparkle update aborted: \(error.localizedDescription, privacy: .public)")
    }

    /// 检查周期结束（含后台自动检查）。error != nil → 记录错误状态；
    /// 无错且未找到更新的情况已由 noteUpdateNotFound 覆盖；找到更新
    /// 时 UI 已交给 Sparkle，这里把 checking 归位为 idle。
    fileprivate func noteUpdateCycleFinished(error: (any Error)?) {
        if let error, !Self.isNoUpdateError(error) {
            status = .error(error.localizedDescription)
            logger.error("Sparkle update cycle failed: \(error.localizedDescription, privacy: .public)")
        } else if error != nil {
            status = .upToDate
        } else if status == .checking {
            status = .idle
        }
    }
}

/// SPUUpdaterDelegate 桥：Sparkle 只接受初始化时注入的 delegate（弱引用）。
/// 转发回 UpdateController（weak，随 owner 同生命周期，controller 持桥、
/// updater 弱持桥，无循环）。Sparkle 在主线程回调；nonisolated + Task
/// 回 MainActor，沿用项目惯例（AppDelegate.userDefaultsDidChange）。
private final class DelegateBridge: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdateController?

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in self.owner?.noteUpdateNotFound() }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in self.owner?.noteUpdateAborted(error) }
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        Task { @MainActor in self.owner?.noteUpdateCycleFinished(error: error) }
    }
}
