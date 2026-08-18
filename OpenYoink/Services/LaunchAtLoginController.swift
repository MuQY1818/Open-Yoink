import Foundation
import ServiceManagement

/// 与 ServiceManagement 解耦的最小接口，便于在不修改系统登录项的情况下测试。
@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginController.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// “登录时启动”的唯一状态源。
///
/// 这里不把开关另存到 UserDefaults：系统设置中的登录项可能被用户随时撤销，
/// 因而 `SMAppService.mainApp.status` 才是实际状态。注册失败时保留系统状态并
/// 把错误反馈给设置页，避免 UI 显示已开启而系统实际未生效。
@MainActor
@Observable
final class LaunchAtLoginController {
    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case unavailable
    }

    private(set) var status: Status = .notRegistered
    private(set) var errorMessage: String?

    /// `.requiresApproval` 表示请求仍已注册，只是被系统设置阻止；开关保持打开，
    /// 并另行提示用户批准。这样用户仍可通过关掉开关完成 unregister。
    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool { status == .requiresApproval }
    var isAvailable: Bool { status != .unavailable }

    private let service: any LaunchAtLoginServicing

    convenience init() {
        self.init(service: SystemLaunchAtLoginService())
    }

    init(service: any LaunchAtLoginServicing) {
        self.service = service
        refresh()
    }

    func refresh() {
        let refreshedStatus = service.status
        if refreshedStatus != status {
            // 用户可能已在系统设置中完成批准/撤销；状态真实变化后，先前一次
            // 注册操作的错误已经过时，不应继续显示。
            errorMessage = nil
        }
        status = refreshedStatus
    }

    func setRequested(_ requested: Bool) {
        errorMessage = nil
        guard isAvailable else { return }
        do {
            if requested {
                guard !isRequested else { return }
                try service.register()
            } else {
                guard isRequested else { return }
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginController.Status {
        Self.map(service.status)
    }

    /// `mainApp` 第一次查询时，Background Task Management 数据库里还没有
    /// 对应记录，系统可能返回 `.notFound`。这并不代表主应用无法注册；首次
    /// `register()` 正是用来创建这条记录。因此把它归一化为“尚未注册”，
    /// 避免 UI 在用户有机会注册之前就错误地禁用开关。
    static func map(_ status: SMAppService.Status) -> LaunchAtLoginController.Status {
        switch status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notRegistered
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
