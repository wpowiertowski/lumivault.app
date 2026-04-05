import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
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
            ReconciliationView()
                .tabItem {
                    Label("Integrity", systemImage: "checkmark.shield")
                }
        }
        .frame(width: 480, height: 420)
    }
}
