import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: LauncherStore
    @EnvironmentObject private var installationManager: InstallationManager
    @EnvironmentObject private var javaInstaller: JavaRuntimeInstaller
    @State private var isShowingLaunchSheet = false
    @State private var isShowingStikDebugFailure = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    accountCard
                    versionCard
                    jitCard
                    if installationManager.isInstalling {
                        InstallationProgressCard()
                    }
                    if javaInstaller.isWorking {
                        JavaProgressContent()
                            .padding()
                            .background(CardBackground())
                    }
                    launchButton
                }
                .padding()
            }
            .navigationTitle("FoldCraft")
            .refreshable {
                store.refreshJitStatus()
                store.refreshInstalledVersions()
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $isShowingLaunchSheet) {
            LaunchView()
        }
        .alert("StikDebug not found", isPresented: $isShowingStikDebugFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Install StikDebug and make sure it is paired, then try again. You can also open StikDebug manually and enable JIT for \(JitService.bundleIdentifier).")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.fill")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fold Craft Launcher")
                    .font(.title2.bold())
                Text("Minecraft: Java Edition for iOS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(CardBackground())
    }

    private var accountCard: some View {
        HStack {
            Image(systemName: "person.crop.circle")
                .font(.title)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Account")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let account = store.selectedAccount {
                    Text(account.playerName)
                        .font(.headline)
                    Text(account.kind.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No account")
                        .font(.headline)
                    Text("Add an account in the Accounts tab")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if !store.accounts.isEmpty {
                Menu {
                    ForEach(store.accounts) { account in
                        Button(account.playerName) {
                            store.selectedAccountIdentifier = account.id
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
        }
        .padding()
        .background(CardBackground())
    }

    private var versionCard: some View {
        HStack {
            Image(systemName: "shippingbox")
                .font(.title)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(store.selectedVersion ?? "No version installed")
                    .font(.headline)
                Text("\(store.installedVersions.count) installed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !store.installedVersions.isEmpty {
                Menu {
                    ForEach(store.installedVersions, id: \.self) { version in
                        Button(version) {
                            store.selectedVersion = version
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
        }
        .padding()
        .background(CardBackground())
    }

    private var jitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: store.isJitEnabled ? "bolt.fill" : "bolt.slash.fill")
                    .font(.title)
                    .foregroundColor(store.isJitEnabled ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JIT")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(store.isJitEnabled ? "Enabled" : "Not enabled")
                        .font(.headline)
                    Text(store.isJitEnabled ? "The Java virtual machine can run at full speed." : "JIT is required to run the Java virtual machine.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    store.refreshJitStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            if !store.isJitEnabled {
                Button {
                    JitService.requestJitFromStikDebug { opened in
                        if !opened {
                            isShowingStikDebugFailure = true
                        }
                    }
                } label: {
                    Label("Enable JIT with StikDebug", systemImage: "ladybug.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(CardBackground())
    }

    private var launchButton: some View {
        Button {
            isShowingLaunchSheet = true
        } label: {
            Label("Launch", systemImage: "play.fill")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.selectedVersion == nil || store.selectedAccount == nil || installationManager.isInstalling || javaInstaller.isWorking)
    }
}

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

struct InstallationProgressCard: View {
    @EnvironmentObject private var installationManager: InstallationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(installationManager.activeVersion ?? "")
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .destructive) {
                    installationManager.cancel()
                }
                .font(.caption)
            }
            Text(installationManager.stage)
                .font(.subheadline)
                .foregroundColor(.secondary)
            ProgressView(value: installationManager.progress)
            if !installationManager.progressDetail.isEmpty {
                Text(installationManager.progressDetail)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(CardBackground())
    }
}
