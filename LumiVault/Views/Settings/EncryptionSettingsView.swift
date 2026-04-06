import SwiftUI

struct EncryptionSettingsView: View {
    @Environment(\.encryptionService) private var encryptionService
    @AppStorage("encryptionEnabled") private var encryptionEnabled = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isKeyLoaded = false
    @State private var storedKeyId: String?
    @State private var showingChangePassphrase = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section("Status") {
                HStack(spacing: 8) {
                    Image(systemName: isKeyLoaded ? "lock.fill" : "lock.open")
                        .foregroundStyle(isKeyLoaded ? .green : .secondary)
                    Text(isKeyLoaded ? "Encryption key loaded" : "No encryption key")
                        .font(Constants.Design.monoBody)
                }

                if let keyId = storedKeyId {
                    HStack {
                        Text("Key ID")
                            .font(Constants.Design.monoCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(keyId)
                            .font(Constants.Design.monoCaption)
                            .textSelection(.enabled)
                    }
                }
            }

            if storedKeyId == nil {
                Section("Set Up Encryption") {
                    SecureField("Passphrase", text: $passphrase)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("encryption.passphrase")
                    SecureField("Confirm Passphrase", text: $confirmPassphrase)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("encryption.confirmPassphrase")

                    Button("Create Encryption Key") {
                        createKey()
                    }
                    .disabled(passphrase.isEmpty || passphrase != confirmPassphrase)
                    .accessibilityIdentifier("encryption.createKey")
                }
            } else {
                Section("Unlock") {
                    if !isKeyLoaded {
                        SecureField("Passphrase", text: $passphrase)
                            .font(Constants.Design.monoBody)
                            .accessibilityIdentifier("encryption.unlockPassphrase")

                        HStack {
                            Button("Unlock") { unlockKey() }
                                .disabled(passphrase.isEmpty)
                                .accessibilityIdentifier("encryption.unlock")
                            Button("Lock") { lockKey() }
                                .disabled(!isKeyLoaded)
                        }
                    } else {
                        Button("Lock Key") { lockKey() }
                    }
                }

                Section("Change Passphrase") {
                    Button("Change Passphrase...") {
                        showingChangePassphrase = true
                    }
                }
            }

            Section {
                Text("Files are encrypted with AES-256-GCM using a key derived from your passphrase via PBKDF2 (600,000 iterations). If you lose your passphrase, encrypted files are permanently unrecoverable. Thumbnails and catalog metadata remain accessible without the key.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.red)
                }
            }

            if let success = successMessage {
                Section {
                    Label(success, systemImage: "checkmark.circle.fill")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingChangePassphrase) {
            ChangePassphraseSheet(encryptionService: encryptionService) {
                refreshState()
            }
        }
        .task { refreshState() }
    }

    private func createKey() {
        errorMessage = nil
        successMessage = nil

        guard passphrase == confirmPassphrase else {
            errorMessage = "Passphrases do not match."
            return
        }

        let salt = EncryptionService.getOrCreateSalt()
        let (key, keyId) = encryptionService.deriveKey(passphrase: passphrase, salt: salt)

        Task {
            await encryptionService.setKey(key, keyId: keyId)
            EncryptionService.storeKeyId(keyId)
            encryptionEnabled = true
            passphrase = ""
            confirmPassphrase = ""
            successMessage = "Encryption key created."
            refreshState()
        }
    }

    private func unlockKey() {
        errorMessage = nil
        successMessage = nil

        let salt = EncryptionService.getOrCreateSalt()
        let (key, keyId) = encryptionService.deriveKey(passphrase: passphrase, salt: salt)

        guard keyId == storedKeyId else {
            errorMessage = "Incorrect passphrase. The derived key does not match."
            return
        }

        Task {
            await encryptionService.setKey(key, keyId: keyId)
            passphrase = ""
            successMessage = "Key unlocked."
            refreshState()
        }
    }

    private func lockKey() {
        Task {
            await encryptionService.clearKey()
            successMessage = nil
            refreshState()
        }
    }

    private func refreshState() {
        storedKeyId = EncryptionService.storedKeyId()
        Task {
            isKeyLoaded = await encryptionService.isKeyAvailable
        }
    }
}

// MARK: - Change Passphrase Sheet

private struct ChangePassphraseSheet: View {
    let encryptionService: EncryptionService
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassphrase = ""
    @State private var newPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Change Passphrase")
                .font(Constants.Design.monoHeadline)

            Form {
                SecureField("Current Passphrase", text: $currentPassphrase)
                    .font(Constants.Design.monoBody)
                SecureField("New Passphrase", text: $newPassphrase)
                    .font(Constants.Design.monoBody)
                SecureField("Confirm New Passphrase", text: $confirmPassphrase)
                    .font(Constants.Design.monoBody)
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.red)
            }

            Text("Changing the passphrase creates a new encryption key. Previously encrypted files will still use the old key. New files will use the new key.")
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Cancel") { dismiss() }
                Button("Change") { changePassphrase() }
                    .disabled(currentPassphrase.isEmpty || newPassphrase.isEmpty || newPassphrase != confirmPassphrase)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }

    private func changePassphrase() {
        errorMessage = nil

        let salt = EncryptionService.getOrCreateSalt()

        // Verify current passphrase
        let (_, currentKeyId) = encryptionService.deriveKey(passphrase: currentPassphrase, salt: salt)
        guard currentKeyId == EncryptionService.storedKeyId() else {
            errorMessage = "Current passphrase is incorrect."
            return
        }

        // Derive new key
        let newSalt = EncryptionService.getOrCreateSalt()
        let (newKey, newKeyId) = encryptionService.deriveKey(passphrase: newPassphrase, salt: newSalt)

        Task {
            await encryptionService.setKey(newKey, keyId: newKeyId)
            EncryptionService.storeKeyId(newKeyId)
            onComplete()
            dismiss()
        }
    }
}
