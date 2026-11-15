import SwiftUI

struct RootView: View {
    @EnvironmentObject private var installationManager: InstallationManager
    @EnvironmentObject private var javaInstaller: JavaRuntimeInstaller

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
        .background(
            Color.clear
                .alert("Java runtime", isPresented: Binding(
                    get: { javaInstaller.resultMessage != nil },
                    set: { if !$0 { javaInstaller.resultMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(javaInstaller.resultMessage ?? "")
                }
        )
        .background(
            Color.clear
                .alert("Java installation failed", isPresented: Binding(
                    get: { javaInstaller.errorMessage != nil },
                    set: { if !$0 { javaInstaller.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(javaInstaller.errorMessage ?? "")
                }
        )
        .onAppear {
            javaInstaller.refresh()
        }
    }
}
