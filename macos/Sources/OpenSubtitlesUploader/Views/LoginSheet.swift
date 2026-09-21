import SwiftUI

struct LoginSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @ViewState private var username = ""
    @ViewState private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text(L("Log in")).font(.title2.bold())
                    Text("OpenSubtitles.org").foregroundStyle(.secondary)
                }
            }

            Form {
                TextField(L("Username"), text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField(L("Password"), text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }
            .formStyle(.columns)

            Text(L("Password is stored securely in your Keychain."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = state.loginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { state.loginCancelled(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    if state.isLoggingIn {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text(L("Log in")).frame(width: 60)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(state.isLoggingIn || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            username = state.username
            state.loginError = nil
            focus = username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        state.login(username: username, password: password)
    }
}
