import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            ExportDefaultsSettingsView()
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            VolumesSettingsView()
                .tabItem {
                    Label("Volumes", systemImage: "externaldrive")
                }
            CloudSettingsView()
                .tabItem {
                    Label("iCloud", systemImage: "icloud")
                }
            B2SettingsView()
                .tabItem {
                    Label("B2", systemImage: "cloud")
                }
            EncryptionSettingsView()
                .tabItem {
                    Label("Encryption", systemImage: "lock.shield")
                }
            ReconciliationView()
                .tabItem {
                    Label("Integrity", systemImage: "checkmark.shield")
                }
            SupportSettingsView()
                .tabItem {
                    Label("Support", systemImage: "heart")
                }
        }
        .frame(width: 540, height: 550)
    }
}
