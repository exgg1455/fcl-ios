import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: LauncherStore
    @State private var isShowingAddAccount = false

    var body: some View {
        NavigationView {
            List {
                if store.accounts.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No accounts")
                                .font(.headline)
                            Button("Add offline account") {
                                isShowingAddAccount = true
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                } else {
                    Section(header: Text("Accounts")) {
                        ForEach(store.accounts) { account in
                            AccountRow(account: account, isSelected: store.selectedAccount?.id == account.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.selectedAccountIdentifier = account.id
                                }
                        }
                        .onDelete { offsets in
                            store.removeAccounts(at: offsets)
                        }
                    }
                }
                Section(footer: Text("Microsoft account sign in will be added in a future update. Offline accounts can play single player worlds and offline mode servers.")) {
                    EmptyView()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $isShowingAddAccount) {
            AddAccountView()
        }
    }
}

struct AccountRow: View {
    let account: GameAccount
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.2))
                Text(String(account.playerName.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundColor(.accentColor)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.playerName)
                    .font(.headline)
                Text(account.kind.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(account.formattedIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var store: LauncherStore
    @Environment(\.dismiss) private var dismiss
    @State private var playerName = ""

    private var isValid: Bool {
        GameAccount.isValidPlayerName(playerName)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Offline account"), footer: Text("3 to 16 characters. Letters, numbers and underscores only.")) {
                    TextField("Player name", text: $playerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                if !playerName.isEmpty {
                    Section(header: Text("Player identifier")) {
                        Text(GameAccount.offline(playerName: playerName).formattedIdentifier)
                            .font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.addOfflineAccount(playerName: playerName)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
