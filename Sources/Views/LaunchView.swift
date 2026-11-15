import SwiftUI
import UIKit

struct LaunchRequirement: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let isSatisfied: Bool
}

struct LaunchView: View {
    @EnvironmentObject private var store: LauncherStore
    @Environment(\.dismiss) private var dismiss
    @State private var requirements: [LaunchRequirement] = []
    @State private var arguments: [String] = []
    @State private var loadError: String?
    @State private var didCopy = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Requirements")) {
                    ForEach(requirements) { requirement in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: requirement.isSatisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(requirement.isSatisfied ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(requirement.title)
                                    .font(.headline)
                                Text(requirement.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if let loadError = loadError {
                    Section(header: Text("Error")) {
                        Text(loadError)
                            .foregroundColor(.red)
                    }
                }

                if !arguments.isEmpty {
                    Section(header: Text("Launch arguments"), footer: Text("\(arguments.count) arguments")) {
                        Text(arguments.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        Button(didCopy ? "Copied" : "Copy arguments") {
                            UIPasteboard.general.string = arguments.joined(separator: " ")
                            didCopy = true
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Launch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: prepare)
        }
    }

    private func prepare() {
        store.refreshJitStatus()
        guard let versionIdentifier = store.selectedVersion, let account = store.selectedAccount else {
            loadError = "Select a version and an account first."
            return
        }
        let detail: VersionDetail
        do {
            detail = try GameDirectory.loadVersionDetail(versionIdentifier)
        } catch {
            loadError = error.localizedDescription
            return
        }

        let requiredJava = detail.requiredJavaMajorVersion
        let runtime = JavaRuntimeLocator.bestRuntime(for: requiredJava)
        let classpath = LaunchArgumentBuilder.classpath(for: detail, identifier: versionIdentifier)
        let missingFiles = classpath.filter { !FileManager.default.fileExists(atPath: $0) }

        requirements = [
            LaunchRequirement(
                title: "Game files",
                detail: missingFiles.isEmpty ? "All \(classpath.count) files are present." : "\(missingFiles.count) files are missing. Use Repair in the Versions tab.",
                isSatisfied: missingFiles.isEmpty
            ),
            LaunchRequirement(
                title: "JIT",
                detail: store.isJitEnabled ? "JIT is enabled." : "Open StikDebug and enable JIT for this app.",
                isSatisfied: store.isJitEnabled
            ),
            LaunchRequirement(
                title: "Java \(requiredJava) runtime",
                detail: runtime.map { "Using \($0.name)." } ?? "No Java runtime built for iOS was found in Files > FCL > java.",
                isSatisfied: runtime != nil
            ),
            LaunchRequirement(
                title: "Account",
                detail: "\(account.playerName) (\(account.kind.title))",
                isSatisfied: true
            )
        ]

        let bounds = UIScreen.main.nativeBounds
        let configuration = LaunchConfiguration(
            versionIdentifier: versionIdentifier,
            detail: detail,
            account: account,
            settings: LauncherSettings.current,
            screenWidth: Int(max(bounds.width, bounds.height)),
            screenHeight: Int(min(bounds.width, bounds.height))
        )
        arguments = LaunchArgumentBuilder.build(configuration)
    }
}
