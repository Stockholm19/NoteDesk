import SwiftUI

struct LoginView: View {
    @Environment(SyncEngine.self) private var engine
    @AppStorage("lastServer") private var server = ""
    @AppStorage("lastUser") private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("NoteDesk").font(.largeTitle.bold())
            Text("Заметки из Note Station на вашем Synology")
                .foregroundStyle(.secondary)

            Form {
                TextField("Адрес DSM", text: $server, prompt: Text("http://192.168.1.10:5000"))
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("Пользователь", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                if needsOTP {
                    TextField("Код 2FA", text: $otp)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)
            .scrollDisabled(true)
            .frame(height: needsOTP ? 230 : 190)

            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Button {
                Task { await submit() }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text(needsOTP ? "Подтвердить" : "Войти") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty || (needsOTP && otp.isEmpty))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let wantsOTP = try await engine.login(server: server, username: username, password: password,
                                                  otp: needsOTP ? otp : nil)
            if wantsOTP { needsOTP = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
