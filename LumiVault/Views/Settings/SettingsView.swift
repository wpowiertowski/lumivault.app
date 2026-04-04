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
        }
        .frame(width: 480, height: 320)
    }
}
