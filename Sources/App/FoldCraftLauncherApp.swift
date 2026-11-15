import SwiftUI

@main
struct FoldCraftLauncherApp: App {
    @StateObject private var store = LauncherStore()
    @StateObject private var installationManager = InstallationManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(installationManager)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                store.refreshJitStatus()
                store.refreshInstalledVersions()
            }
        }
    }
}
