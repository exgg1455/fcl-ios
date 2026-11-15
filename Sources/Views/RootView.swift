import SwiftUI

struct RootView: View {
    @EnvironmentObject private var installationManager: InstallationManager

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            VersionsView()
                .tabItem { Label("Versions", systemImage: "square.stack.3d.up.fill") }
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .alert("Download failed", isPresented: Binding(
            get: { installationManager.errorMessage != nil },
            set: { if !$0 { installationManager.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installationManager.errorMessage ?? "")
        }
    }
}
