import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (S8): four tabs — General / Triggers / Ignored Apps /
/// About — in the system form style (Form + grouped sections + native
/// controls). All user-visible strings are LocalizedStringKey literals,
/// resolved through Localizable.xcstrings (S10); runtime-computed fallbacks
/// use `String(localized:)` explicitly.
///
/// Presented via the SwiftUI `Settings` scene (`OpenYoinkApp`); opened from
/// the menu bar (`MenuBarController.showSettings`). `SettingsStore` and
/// `HotKeyMonitor` arrive through the environment.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            TriggerSettingsTab()
                .tabItem { Label("Triggers", systemImage: "keyboard") }
            IgnoredAppsSettingsTab()
                .tabItem { Label("Ignored Apps", systemImage: "hand.raised") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Shelf") {
                Picker("Position", selection: $settings.shelfPosition) {
                    Text("Left").tag(SettingsStore.ShelfPosition.left)
                    Text("Right").tag(SettingsStore.ShelfPosition.right)
                    Text("Custom").tag(SettingsStore.ShelfPosition.custom)
                }
                .pickerStyle(.segmented)

                if settings.shelfPosition == .custom {
                    // S9: custom 模式 —— 面板可拖动，拖动结束持久化 frame；
                    // 首次选中从右缘默认位置起步。边缘触发在无贴附缘时暂停。
                    Text("Drag the shelf by its title bar to place it anywhere. The edge trigger is unavailable in custom mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Width") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.shelfWidth, in: 240...480, step: 10)
                        Text("\(Int(settings.shelfWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                Toggle("Hide after dragging out", isOn: $settings.autoHide)

                // UX6: 非空→空迁移时自动收回（手动唤出的空架不受影响）。
                Toggle("Hide automatically when empty", isOn: $settings.autoHideWhenEmpty)

                Picker("After dragging out", selection: $settings.dragOutRemovalPolicy) {
                    Text("Keep on Shelf").tag(SettingsStore.DragOutRemovalPolicy.keep)
                    Text("Remove").tag(SettingsStore.DragOutRemovalPolicy.remove)
                    Text("Ask Every Time").tag(SettingsStore.DragOutRemovalPolicy.ask)
                }

                // F-05: 双模式拖入说明（静态文案）。
                Text("Dropping files keeps a reference. Hold ⌘ while dropping to move the original into the shelf — the original goes to the Trash, so it can be restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text("System").tag(SettingsStore.LanguagePreference.system)
                    Text("English").tag(SettingsStore.LanguagePreference.english)
                    Text("中文").tag(SettingsStore.LanguagePreference.chinese)
                }
                // S10: AppleLanguages 覆盖在启动最早期应用（AppDelegate.
                // applicationWillFinishLaunching），运行期切换故需重启生效。
                Text("Takes effect after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Triggers

private struct TriggerSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HotKeyMonitor.self) private var hotKeyMonitor

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Global Hot Key") {
                Toggle("Enable", isOn: $settings.hotKeyEnabled)

                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(shortcut: $settings.hotKeyShortcut)
                        Button("Restore Default") {
                            settings.hotKeyShortcut = .default
                        }
                        .disabled(settings.hotKeyShortcut == .default)
                    }
                }

                // UX3: 双击保存剪贴板。开启时单击带一个识别窗的延迟 —— 脚注
                // 说明此取舍；关闭即恢复零延迟单击。
                Toggle("Double-press saves clipboard", isOn: $settings.hotKeyDoublePressSavesClipboard)
                    .disabled(!settings.hotKeyEnabled)
                Text("When enabled, a single press toggles the shelf after a brief delay (0.3 s) so a double press can be recognized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = hotKeyMonitor.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // UX1/2: 拖拽自动出现（Yoink 核心交互）。三档单控：立即出现 /
            // 拖到贴边唤出 / 无动作。边缘灵敏度沿用旧边缘触发的三档设置。
            Section("When Dragging Files") {
                Picker("When Dragging Files", selection: $settings.dragAutoAppearMode) {
                    Text("Show immediately").tag(SettingsStore.DragAutoAppearMode.immediate)
                    Text("Show at screen edge").tag(SettingsStore.DragAutoAppearMode.edgeOnly)
                    Text("Do nothing").tag(SettingsStore.DragAutoAppearMode.off)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Picker("Sensitivity", selection: $settings.edgeTriggerSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(settings.dragAutoAppearMode != .edgeOnly)

                Text(dragModeFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag triggers stay silent while an ignored app is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse Shake") {
                Toggle("Shake the mouse to show the shelf", isOn: $settings.shakeTriggerEnabled)
                Picker("Sensitivity", selection: $settings.shakeSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(!settings.shakeTriggerEnabled)
            }
        }
        .formStyle(.grouped)
    }

    /// UX1/2: 随模式变化的说明文案（immediate 无需贴边；edgeOnly 在 custom
    /// 位置下不可用）。
    private var dragModeFootnote: String {
        switch settings.dragAutoAppearMode {
        case .immediate:
            String(localized: "The shelf appears at its configured position as soon as you start dragging — no need to reach the screen edge.")
        case .edgeOnly:
            String(localized: "While dragging, hold the cursor at the shelf's screen edge for a moment to reveal it. Not available in custom position mode.")
        case .off:
            String(localized: "The shelf won't appear automatically while dragging.")
        }
    }
}

// MARK: - Ignored Apps

private struct IgnoredAppsSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selection: Set<String> = []
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                        IgnoredAppRow(bundleID: bundleID).tag(bundleID)
                    }
                }
                .frame(minHeight: 160)
                .onDeleteCommand {
                    settings.removeIgnoredApps(bundleIDs: selection)
                    selection.removeAll()
                }

                HStack {
                    Menu("Add…") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button {
                                if let bundleID = app.bundleIdentifier {
                                    settings.addIgnoredApp(bundleID: bundleID)
                                }
                            } label: {
                                Label {
                                    Text(app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown"))
                                } icon: {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Choose Application…") { chooseApplication() }
                    }
                    .fixedSize()

                    Spacer()

                    Button("Remove") {
                        settings.removeIgnoredApps(bundleIDs: selection)
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                }
            } header: {
                Text("Ignored Apps")
            } footer: {
                Text("Shake and drag triggers stay silent while one of these apps is frontmost. The global hot key is never filtered.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadRunningApps() }
    }

    private func reloadRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// NSOpenPanel on /Applications — sandbox-legal because the user picks the
    /// app explicitly (user-selected read entitlement).
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.addIgnoredApp(bundleID: bundleID)
    }
}

/// One ignore-list entry: app icon, display name, bundle identifier. Icon and
/// name resolve through NSWorkspace even when the app isn't running; an app
/// that can no longer be located degrades to a dashed placeholder + raw ID.
private struct IgnoredAppRow: View {
    let bundleID: String

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let appURL else { return bundleID }
        let bundle = Bundle(url: appURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionString)
                LabeledContent("License", value: "MIT")
            }

            Section("Acknowledgments") {
                Text("Open-Yoink is a clean-room implementation that studied the observable behavior of several MIT-licensed open-source shelf apps (HoldMac, DropKit, ShelfMate, NotchPocket, nab, Dropshit). No third-party code is included. See THIRD_PARTY_NOTICES.md in the source repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
