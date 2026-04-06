import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings.tab.general")
            ExportDefaultsSettingsView()
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.tab.export")
            VolumesSettingsView()
                .tabItem {
                    Label("Volumes", systemImage: "externaldrive")
                }
                .accessibilityIdentifier("settings.tab.volumes")
            CloudSettingsView()
                .tabItem {
                    Label("iCloud", systemImage: "icloud")
                }
                .accessibilityIdentifier("settings.tab.icloud")
            B2SettingsView()
                .tabItem {
                    Label("B2", systemImage: "cloud")
                }
                .accessibilityIdentifier("settings.tab.b2")
            EncryptionSettingsView()
                .tabItem {
                    Label("Encryption", systemImage: "lock.shield")
                }
                .accessibilityIdentifier("settings.tab.encryption")
            ReconciliationView()
                .tabItem {
                    Label("Integrity", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("settings.tab.integrity")
            SupportSettingsView()
                .tabItem {
                    Label("Support", systemImage: "heart")
                }
                .accessibilityIdentifier("settings.tab.support")
        }
        .frame(width: 540, height: 550)
    }
}
