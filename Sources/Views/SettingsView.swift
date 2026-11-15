import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LauncherStore
    @AppStorage(SettingsKey.memoryAllocation) private var memoryAllocation = DeviceInformation.recommendedMemory
    @AppStorage(SettingsKey.jvmArguments) private var jvmArguments = ""
    @AppStorage(SettingsKey.gameArguments) private var gameArguments = ""
    @AppStorage(SettingsKey.downloadSource) private var downloadSource = DownloadSource.official.rawValue
    @AppStorage(SettingsKey.downloadConcurrency) private var downloadConcurrency = 16
    @AppStorage(SettingsKey.resolutionScale) private var resolutionScale = 1.0
    @State private var storageDescription = "Calculating"
    @State private var javaRuntimes: [JavaRuntime] = []

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Game")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Memory")
                            Spacer()
                            Text("\(memoryAllocation) MB")
                                .foregroundColor(.secondary)
                                .font(.body.monospacedDigit())
                        }
                        Slider(
                            value: Binding(
                                get: { Double(memoryAllocation) },
                                set: { memoryAllocation = Int($0 / 128) * 128 }
                            ),
                            in: 512...Double(DeviceInformation.maximumMemory),
                            step: 128
                        )
                        Text("Device memory: \(DeviceInformation.physicalMemory) MB")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Resolution scale")
                            Spacer()
                            Text("\(Int(resolutionScale * 100))%")
                                .foregroundColor(.secondary)
                                .font(.body.monospacedDigit())
                        }
                        Slider(value: $resolutionScale, in: 0.25...1.0, step: 0.05)
                    }
                }

                Section(header: Text("Java virtual machine arguments")) {
                    TextEditor(text: $jvmArguments)
                        .font(.caption.monospaced())
                        .frame(minHeight: 70)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section(header: Text("Game arguments")) {
                    TextEditor(text: $gameArguments)
                        .font(.caption.monospaced())
                        .frame(minHeight: 50)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                Section(header: Text("Download")) {
                    Picker("Source", selection: $downloadSource) {
                        ForEach(DownloadSource.allCases) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }
                    Stepper(value: $downloadConcurrency, in: 1...64) {
                        HStack {
                            Text("Parallel downloads")
                            Spacer()
                            Text("\(downloadConcurrency)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Java runtime")) {
                    NavigationLink(destination: JavaRuntimesView()) {
                        HStack {
                            Label("Java Runtimes", systemImage: "cup.and.saucer.fill")
                            Spacer()
                            Text(javaSummary)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("JIT")) {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(store.isJitEnabled ? "Enabled" : "Not enabled")
                            .foregroundColor(store.isJitEnabled ? .green : .orange)
                    }
                    Button("Enable JIT with StikDebug") {
                        JitService.requestJitFromStikDebug { _ in }
                    }
                    .disabled(store.isJitEnabled)
                    Button("Refresh status") {
                        store.refreshJitStatus()
                    }
                }

                Section(header: Text("Storage")) {
                    HStack {
                        Text("Game directory")
                        Spacer()
                        Text(storageDescription)
                            .foregroundColor(.secondary)
                    }
                    Text(GameDirectory.root.path)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("System")
                        Spacer()
                        Text(DeviceInformation.operatingSystemDescription)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Bundle identifier")
                        Spacer()
                        Text(JitService.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Based on Fold Craft Launcher by FCL Team. Licensed under GPL 3.0.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: refreshInformation)
        }
        .navigationViewStyle(.stack)
    }

    private var javaSummary: String {
        let usable = javaRuntimes.filter { $0.platform.isUsableOnDevice }.count
        if javaRuntimes.isEmpty {
            return "None"
        }
        return "\(usable) of \(javaRuntimes.count) usable"
    }

    private func refreshInformation() {
        javaRuntimes = JavaRuntimeLocator.installedRuntimes()
        Task.detached(priority: .utility) {
            let size = GameDirectory.directorySize(GameDirectory.root)
            let text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            await MainActor.run {
                storageDescription = text
            }
        }
    }
}
