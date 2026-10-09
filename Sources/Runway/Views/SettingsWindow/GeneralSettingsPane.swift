import KeyboardShortcuts
import SwiftUI

/// The Settings window's General pane: app behavior (login item, global shortcut), iCloud sync,
/// and privacy.
struct GeneralSettingsPane: View {
    @Environment(AppContainer.self) private var container

    @State private var launchAtLogin = LaunchAtLoginSetting()
    private let density = DensitySetting.compact

    var body: some View {
        @Bindable var privacy = container.privacy
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            SettingsSection("General") {
                SettingsRow("Launch at Login") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.update(to: $0) }
                    ))
                        .settingsSwitchStyle()
                }
                if let launchAtLoginError = launchAtLogin.errorMessage {
                    SettingsInlineNotice(launchAtLoginError)
                }
                // Click-to-record field; its ⓧ clears the combo and disables the shortcut.
                SettingsRow("Global Shortcut") {
                    ShortcutRecorderField(name: .togglePopover)
                        .hoverTooltip("Open Runway from anywhere")
                }
            }
            ICloudSyncSettingsSection(sync: container.iCloudSync)
            SettingsSection("Privacy") {
                SettingsRow("Hide From Screen Share") {
                    Toggle("", isOn: $privacy.hideUsageWhileScreenSharing)
                        .settingsSwitchStyle()
                }
                SettingsCaption("While your screen is shared or recorded, the menu bar shows “Runway” instead of your usage.")
            }
        }
    }
}
