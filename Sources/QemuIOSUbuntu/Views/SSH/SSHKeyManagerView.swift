import SwiftUI
import UIKit

/// Gerenciador de chaves SSH integrado: gera chaves Ed25519 no Keychain,
/// importa chaves OpenSSH/Base64 e permite copiar/exportar chaves públicas e privadas.
public struct SSHKeyManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sshService: SSHService

    @State private var isShowingGenerateAlert = false
    @State private var newKeyName = "iPhone-Ubuntu"
    @State private var isShowingImportSheet = false
    @State private var importKeyName = "Chave Importada"
    @State private var importKeyContent = ""
    @State private var isShowingFileImporter = false
    @State private var exportedItemText: String?
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        isShowingGenerateAlert = true
                    } label: {
                        Label("Gerar Nova Chave Ed25519", systemImage: "key.fill")
                    }

                    Button {
                        isShowingImportSheet = true
                    } label: {
                        Label("Importar Chave Privada (Texto / PEM)", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Importar Arquivo de Chave", systemImage: "doc")
                    }
                } header: {
                    Text("Ações")
                } footer: {
                    Text("As chaves privadas são armazenadas no Keychain protegido do iOS. Copie a chave pública (`ssh-ed25519`) para `~/.ssh/authorized_keys` no Ubuntu Server.")
                }

                Section("Chaves Salvas (\(sshService.keys.count))") {
                    if sshService.keys.isEmpty {
                        Text("Nenhuma chave SSH cadastrada.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sshService.keys) { key in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(key.name)
                                        .font(.headline)
                                    Spacer()
                                    Text(key.algorithm.rawValue)
                                        .font(.caption2.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                }

                                Text(key.fingerprintSHA256)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                HStack(spacing: 10) {
                                    Button("Copiar Pública") {
                                        UIPasteboard.general.string = key.publicKeyOpenSSH
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)

                                    Button("Exportar PEM") {
                                        do {
                                            exportedItemText = try sshService.exportOpenSSHPrivateKeyPEM(for: key)
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)

                                    Spacer()

                                    Button(role: .destructive) {
                                        try? sshService.deleteKey(id: key.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Chaves SSH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluir") { dismiss() }
                }
            }
            .alert("Gerar Chave Ed25519", isPresented: $isShowingGenerateAlert) {
                TextField("Nome da chave", text: $newKeyName)
                Button("Cancelar", role: .cancel) {}
                Button("Gerar") {
                    do {
                        _ = try sshService.generateEd25519Key(name: newKeyName.isEmpty ? "Ed25519" : newKeyName)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: $isShowingImportSheet) {
                NavigationStack {
                    Form {
                        Section("Identificação") {
                            TextField("Nome da chave", text: $importKeyName)
                        }
                        Section("Chave Privada OpenSSH Ed25519 ou Seed Base64") {
                            TextEditor(text: $importKeyContent)
                                .font(.caption.monospaced())
                                .frame(minHeight: 180)
                        }
                    }
                    .navigationTitle("Importar Chave")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") { isShowingImportSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Importar") {
                                do {
                                    _ = try sshService.importPrivateKey(name: importKeyName, pemOrBase64: importKeyContent)
                                    importKeyContent = ""
                                    isShowingImportSheet = false
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingFileImporter) {
                DocumentPickerView(contentTypes: [.text, .data]) { urls in
                    guard let url = urls.first else { return }
                    let stop = url.startAccessingSecurityScopedResource()
                    defer { if stop { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        _ = try sshService.importPrivateKey(name: url.lastPathComponent, pemOrBase64: content)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { exportedItemText != nil },
                    set: { if !$0 { exportedItemText = nil } }
                )
            ) {
                if let text = exportedItemText {
                    ShareSheetView(items: [text])
                }
            }
            .alert(
                "Erro",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

