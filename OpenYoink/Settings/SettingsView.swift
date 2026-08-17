import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (S8): four tabs — General / Triggers / Ignored Apps /
/// About — in the system form style (Form + grouped sections + native
/// controls). Strings are English originals for now and are written so they
/// can be lifted straight into Localizable.xcstrings in S10.
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
                }
                .pickerStyle(.segmented)

                LabeledContent("Width") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.shelfWidth, in: 240...480, step: 10)
                        Text("\(Int(settings.shelfWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                Toggle("Hide after dragging out", isOn: $settings.autoHide)

                Picker("After dragging out", selection: $settings.dragOutRemovalPolicy) {
                    Text("Keep on Shelf").tag(SettingsStore.DragOutRemovalPolicy.keep)
                    Text("Remove").tag(SettingsStore.DragOutRemovalPolicy.remove)
                    Text("Ask Every Time").tag(SettingsStore.DragOutRemovalPolicy.ask)
                }
            }

            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text("System").tag(SettingsStore.LanguagePreference.system)
                    Text("English").tag(SettingsStore.LanguagePreference.english)
                    Text("中文").tag(SettingsStore.LanguagePreference.chinese)
                }
                Text("Takes effect after relaunch. Interface localization ships in a later update; this stores your preference.")
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

                if let error = hotKeyMonitor.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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

            Section("Screen Edge") {
                Toggle("Show when the cursor rests on the shelf edge", isOn: $settings.edgeTriggerEnabled)
                Picker("Sensitivity", selection: $settings.edgeTriggerSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(!settings.edgeTriggerEnabled)
            }
        }
        .formStyle(.grouped)
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
                                    Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
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
                Text("Shake and edge triggers stay silent while one of these apps is frontmost. The global hot key is never filtered.")
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
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
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
