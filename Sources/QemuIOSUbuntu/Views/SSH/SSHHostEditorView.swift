import SwiftUI

/// Formulário para criar ou editar um perfil de host SSH salvo.
public struct SSHHostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sshService: SSHService
    @EnvironmentObject private var sshVM: SSHViewModel

    @State private var draft: SSHHostProfile
    @State private var portText: String
    @State private var passwordInput: String
    private let isCreating: Bool

    public init(host: SSHHostProfile? = nil) {
        if let host {
            _draft = State(initialValue: host)
            _portText = State(initialValue: String(host.port))
            _passwordInput = State(initialValue: "")
            self.isCreating = false
        } else {
            let fresh = SSHHostProfile(name: "Servidor Ubuntu", host: "127.0.0.1", port: 2222, username: "ubuntu")
            _draft = State(initialValue: fresh)
            _portText = State(initialValue: "2222")
            _passwordInput = State(initialValue: "")
            self.isCreating = true
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Servidor") {
                    TextField("Nome (ex: Ubuntu Local)", text: $draft.name)
                    TextField("Host / IP (ex: 127.0.0.1)", text: $draft.host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Porta", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("Usuário", text: $draft.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Autenticação") {
                    Picker("Método", selection: $draft.authType) {
                        ForEach(SSHAuthType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }

                    if draft.authType == .password {
                        SecureField(
                            isCreating ? "Senha (salva no Keychain)" : "Nova senha (deixe vazio para manter)",
                            text: $passwordInput
                        )
                    } else {
                        if sshService.keys.isEmpty {
                            Text("Nenhuma chave SSH cadastrada. Crie ou importe uma no Gerenciador de Chaves.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Chave Privada", selection: $draft.keyId) {
                                Text("Selecione uma chave...").tag(UUID?.none)
                                ForEach(sshService.keys) { key in
                                    Text("\(key.name) (\(key.algorithm.rawValue))").tag(UUID?.some(key.id))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isCreating ? "Novo Host SSH" : "Editar Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        draft.port = UInt16(portText) ?? 22
                        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            draft.name = "\(draft.username)@\(draft.host)"
                        }
                        sshVM.saveHost(draft, password: passwordInput.isEmpty ? nil : passwordInput)
                        dismiss()
                    }
                    .disabled(draft.host.trimmingCharacters(in: .whitespaces).isEmpty || draft.username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if !isCreating, passwordInput.isEmpty {
                    passwordInput = sshService.loadPassword(for: draft.id) ?? ""
                }
            }
        }
    }
}

