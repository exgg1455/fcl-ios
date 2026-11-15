import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct JavaRuntimesView: View {
    @StateObject private var installer = JavaRuntimeInstaller()
    @State private var importMode: ImportMode?
    @State private var isShowingImporter = false
    @State private var isShowingDownload = false
    @State private var pendingRemoval: JavaRuntime?

    enum ImportMode {
        case archive
        case folder

        var contentTypes: [UTType] {
            switch self {
            case .archive: return [.item]
            case .folder: return [.folder]
            }
        }
    }

    var body: some View {
        List {
            if installer.isWorking {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(installer.stage)
                                .font(.headline)
                            Spacer()
                            Text("\(Int(installer.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        ProgressView(value: installer.progress)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text("Installed")) {
                if installer.runtimes.isEmpty {
                    Text("No Java runtime installed")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(installer.runtimes) { runtime in
                        JavaRuntimeRow(runtime: runtime)
                            .swipeActions(edge: .trailing) {
                                if !runtime.isBundled {
                                    Button(role: .destructive) {
                                        pendingRemoval = runtime
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }

            Section(
                header: Text("Install"),
                footer: Text("The runtime must be an OpenJDK build for iOS arm64 (the same kind Amethyst and PojavLauncher for iOS use). Android or Linux builds are detected and marked as unusable. Supported files: .tar, .tar.gz and .tar.xz. For a zip or ipa file, extract it in the Files app first and use Import Folder.")
            ) {
                Button {
                    importMode = .archive
                    isShowingImporter = true
                } label: {
                    Label("Import Archive", systemImage: "doc.zipper")
                }
                Button {
                    importMode = .folder
                    isShowingImporter = true
                } label: {
                    Label("Import Folder", systemImage: "folder")
                }
                Button {
                    isShowingDownload = true
                } label: {
                    Label("Download from Link", systemImage: "arrow.down.circle")
                }
            }
            .disabled(installer.isWorking)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Java Runtimes")
        .onAppear { installer.refresh() }
        .refreshable { installer.refresh() }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: importMode?.contentTypes ?? [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let files) = result, let file = files.first else {
                if case .failure(let error) = result {
                    installer.errorMessage = error.localizedDescription
                }
                return
            }
            if importMode == .folder {
                installer.importFolder(from: file)
            } else {
                installer.importArchive(from: file)
            }
        }
        .sheet(isPresented: $isShowingDownload) {
            JavaDownloadView { address in
                installer.download(from: address)
            }
        }
        .alert("Java runtime", isPresented: Binding(
            get: { installer.resultMessage != nil },
            set: { if !$0 { installer.resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installer.resultMessage ?? "")
        }
        .alert("Installation failed", isPresented: Binding(
            get: { installer.errorMessage != nil },
            set: { if !$0 { installer.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(installer.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \(pendingRemoval?.name ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let runtime = pendingRemoval {
                    installer.remove(runtime)
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        }
    }
}

struct JavaRuntimeRow: View {
    let runtime: JavaRuntime

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.title2)
                .foregroundColor(runtime.platform.isUsableOnDevice ? .accentColor : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(runtime.name)
                        .font(.headline)
                    if runtime.isBundled {
                        Text("Bundled")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                Text(runtime.fullVersion.map { "Version \($0)" } ?? "Unknown version")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: runtime.platform.isUsableOnDevice ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    Text(runtime.platform.isUsableOnDevice ? "\(runtime.platform.title) build" : "\(runtime.platform.title) build, not usable on iOS")
                }
                .font(.caption)
                .foregroundColor(runtime.platform.isUsableOnDevice ? .green : .orange)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct JavaDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    let onDownload: (URL) -> Void

    private var address: URL? {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = URL(string: trimmed),
              let scheme = candidate.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              candidate.host != nil else { return nil }
        return candidate
    }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("Archive link"),
                    footer: Text("Direct link to a .tar, .tar.gz or .tar.xz file that contains a Java runtime built for iOS.")
                ) {
                    TextField("https://", text: $addressText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button("Paste") {
                        addressText = UIPasteboard.general.string ?? addressText
                    }
                }
            }
            .navigationTitle("Download Java")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        if let address = address {
                            onDownload(address)
                        }
                        dismiss()
                    }
                    .disabled(address == nil)
                }
            }
        }
    }
}
