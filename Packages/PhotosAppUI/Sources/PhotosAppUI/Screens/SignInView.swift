import Core
import CloudCore
import SwiftUI

struct SignInView: View {
    let model: AppModel
    /// Prefilled when adding a second account or re-signing in.
    var initialEmail = ""
    var onSignedIn: (() -> Void)?

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            } header: {
                Text("Cloud account")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            }

            Section {
                Button(action: signIn) {
                    HStack {
                        Text("Sign In")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking || email.isEmpty || password.isEmpty)
            }

            ServerAddressSection(model: model)
        }
        .navigationTitle("Photos")
        .onAppear {
            if email.isEmpty { email = initialEmail }
        }
    }

    private func signIn() {
        guard !isWorking, !email.isEmpty, !password.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.signIn(email: email, password: password)
                password = ""
                onSignedIn?()
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// Editable local/remote addresses with a per-address connection test.
struct ServerAddressSection: View {
    let model: AppModel

    @State private var local = ""
    @State private var remote = ""
    @State private var report: [String]?
    @State private var isTesting = false

    var body: some View {
        Section {
            LabeledContent("Home") {
                TextField("192.168.1.10:2283", text: $local)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Away") {
                TextField("100.64.0.10:2283", text: $remote)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                test()
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
            if let report {
                ForEach(report, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(line.contains("OK") ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The home address is used when it answers within 1.5 seconds; otherwise the away address (Tailscale).")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onAppear {
            local = model.serverSettings.addresses.local?.absoluteString ?? ""
            remote = model.serverSettings.addresses.remote?.absoluteString ?? ""
        }
        .onChange(of: local) { save() }
        .onChange(of: remote) { save() }
    }

    private func save() {
        let addresses = ServerAddresses(local: ServerAddresses.normalize(local), remote: ServerAddresses.normalize(remote))
        guard addresses != model.serverSettings.addresses else { return }
        model.serverSettings.addresses = addresses
        model.reconnect()
    }

    private func test() {
        isTesting = true
        Task {
            report = await model.connectivityReport()
            isTesting = false
        }
    }
}
