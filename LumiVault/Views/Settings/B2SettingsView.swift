import SwiftUI

struct B2SettingsView: View {
    @AppStorage("b2Enabled") private var b2Enabled = false
    @AppStorage("b2BucketName") private var bucketName = ""
    @State private var keyId = ""
    @State private var applicationKey = ""
    @State private var bucketId = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?

    var body: some View {
        Form {
            Section("Backblaze B2") {
                Toggle("Enable B2 cloud uploads", isOn: $b2Enabled)
            }

            if b2Enabled {
                Section("Credentials") {
                    TextField("Application Key ID", text: $keyId)
                        .font(Constants.Design.monoBody)
                    SecureField("Application Key", text: $applicationKey)
                        .font(Constants.Design.monoBody)
                }

                Section("Bucket") {
                    TextField("Bucket ID", text: $bucketId)
                        .font(Constants.Design.monoBody)
                    TextField("Bucket Name", text: $bucketName)
                        .font(Constants.Design.monoBody)
                }

                Section {
                    HStack {
                        Button("Test Connection") { testConnection() }
                            .disabled(keyId.isEmpty || applicationKey.isEmpty || isTesting)

                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let result = testResult {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? Color.green : Color.red)
                            Text(result.message)
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(result.success ? Color.secondary : Color.red)
                        }

                        Spacer()

                        Button("Save") { saveCredentials() }
                            .disabled(keyId.isEmpty || applicationKey.isEmpty || bucketId.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { loadCredentials() }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let service = B2Service()
            let credentials = B2Credentials(
                applicationKeyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
                applicationKey: applicationKey.trimmingCharacters(in: .whitespacesAndNewlines),
                bucketId: bucketId.trimmingCharacters(in: .whitespacesAndNewlines),
                bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            do {
                try await service.authorize(credentials: credentials)
                testResult = TestResult(success: true, message: "Connected successfully")
            } catch {
                testResult = TestResult(success: false, message: error.localizedDescription)
            }

            isTesting = false
        }
    }

    private func saveCredentials() {
        let credentials = B2Credentials(
            applicationKeyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationKey: applicationKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketId: bucketId.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: B2Credentials.keychainKey)
        }
    }

    private func loadCredentials() {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.keychainKey),
              let credentials = try? JSONDecoder().decode(B2Credentials.self, from: data) else { return }
        keyId = credentials.applicationKeyId
        applicationKey = credentials.applicationKey
        bucketId = credentials.bucketId
        bucketName = credentials.bucketName
    }

    private struct TestResult {
        let success: Bool
        let message: String
    }
}
