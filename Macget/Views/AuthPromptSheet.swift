import SwiftUI

/// Username/password sheet shown when a download's server returns 401/407.
struct AuthPromptSheet: View {
    @Bindable var model: AuthPromptModel
    @State private var user = ""
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sign in")
                        .font(.headline)
                    if let host = model.request?.host, !host.isEmpty {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
            Divider()
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Username")
                    TextField("", text: $user)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Toggle("Remember in Keychain", isOn: $remember)
                .font(.callout)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") {
                    model.submit(user: user, password: password, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(user.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { if user.isEmpty { user = model.request?.suggestedUser ?? "" } }
    }
}
