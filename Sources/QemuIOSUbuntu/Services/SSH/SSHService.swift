import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import SwiftTerm

/// Representa uma aba de sessão SSH interativa em andamento.
@MainActor
public final class SSHSessionTab: ObservableObject, Identifiable {
    public let id = UUID()
    public let profile: SSHHostProfile
    @Published public var title: String
    @Published public var state: SSHConnectionState = .disconnected
    @Published public var cols: Int = 80
    @Published public var rows: Int = 24

    fileprivate var stdinWriter: TTYStdinWriter?
    fileprivate var client: SSHClient?
    fileprivate var sessionTask: Task<Void, Never>?
    fileprivate var scrollbackBuffer = Data()
    private let maxScrollbackBytes = 256 * 1024
    fileprivate weak var attachedTerminalView: TerminalView?

    public init(profile: SSHHostProfile) {
        self.profile = profile
        self.title = "\(profile.username)@\(profile.host):\(profile.port)"
    }

    public func attach(terminalView: TerminalView) {
        attachedTerminalView = terminalView
        if !scrollbackBuffer.isEmpty {
            let bytes = [UInt8](scrollbackBuffer)
            terminalView.feed(byteArray: ArraySlice(bytes))
        }
    }

    fileprivate func appendOutput(_ data: Data) {
        scrollbackBuffer.append(data)
        if scrollbackBuffer.count > maxScrollbackBytes {
            scrollbackBuffer.removeFirst(scrollbackBuffer.count - maxScrollbackBytes)
        }
        if let view = attachedTerminalView {
            let bytes = [UInt8](data)
            view.feed(byteArray: ArraySlice(bytes))
        }
    }

    public func sendBytes(_ bytes: [UInt8]) {
        guard let writer = stdinWriter else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        Task {
            try? await writer.write(buffer)
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, (cols != self.cols || rows != self.rows) else { return }
        self.cols = cols
        self.rows = rows
        guard let writer = stdinWriter else { return }
        Task {
            try? await writer.changeSize(cols: cols, rows: rows)
        }
    }

    public func closeSession() {
        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter = nil
        let activeClient = client
        client = nil
        Task {
            try? await activeClient?.close()
        }
        state = .disconnected
    }
}

/// Serviço completo de cliente SSH com Citadel (SwiftNIO SSH) e gerenciador de chaves CryptoKit/OpenSSH.
@MainActor
public final class SSHService: ObservableObject {
    @Published public private(set) var savedHosts: [SSHHostProfile] = []
    @Published public private(set) var keys: [SSHKeyPair] = []
    @Published public private(set) var tabs: [SSHSessionTab] = []
    @Published public var selectedTabId: UUID?

    private let storageService: StorageService

    public init(storageService: StorageService) {
        self.storageService = storageService
        self.savedHosts = storageService.loadSSHHosts()
        self.keys = storageService.loadSSHKeys()

        if savedHosts.isEmpty {
            // Host padrão pré-configurado apontando para a VM Ubuntu local via porta NAT 2222
            let defaultHost = SSHHostProfile(
                name: "Ubuntu Server Local (VM)",
                host: "127.0.0.1",
                port: 2222,
                username: "ubuntu",
                authType: .password
            )
            savedHosts = [defaultHost]
            try? storageService.saveSSHHosts(savedHosts)
        }
    }

    // MARK: - Hosts Salvos

    public func upsertHost(_ profile: SSHHostProfile) throws {
        if let index = savedHosts.firstIndex(where: { $0.id == profile.id }) {
            savedHosts[index] = profile
        } else {
            savedHosts.append(profile)
        }
        try storageService.saveSSHHosts(savedHosts)
    }

    public func deleteHost(id: UUID) throws {
        savedHosts.removeAll { $0.id == id }
        KeychainHelper.delete(account: "sshpass-\(id.uuidString)")
        try storageService.saveSSHHosts(savedHosts)
    }

    public func savePassword(_ password: String, for hostId: UUID) throws {
        if let data = password.data(using: .utf8) {
            try KeychainHelper.save(data: data, account: "sshpass-\(hostId.uuidString)")
        }
    }

    public func loadPassword(for hostId: UUID) -> String? {
        guard let data = KeychainHelper.load(account: "sshpass-\(hostId.uuidString)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Gerenciador de Chaves SSH (Ed25519 / P-256)

    /// Gera um novo par Ed25519 via CryptoKit, formata a chave pública em padrão OpenSSH (`ssh-ed25519 AAAA...`)
    /// e armazena a chave privada com segurança no Keychain do iOS.
    public func generateEd25519Key(name: String, comment: String = "qemu-ios-ubuntu") throws -> SSHKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        let rawPub = privateKey.publicKey.rawRepresentation
        let openSSHBlob = buildOpenSSHEd25519Blob(publicKeyRaw: rawPub)
        let openSSHPublic = "ssh-ed25519 \(openSSHBlob.base64EncodedString()) \(comment)"
        let fingerprint = "SHA256:\(SHA256.hash(data: openSSHBlob).withUnsafeBytes { Data($0).base64EncodedString().replacingOccurrences(of: "=", with: "") })"

        let pair = SSHKeyPair(
            name: name,
            algorithm: .ed25519,
            publicKeyOpenSSH: openSSHPublic,
            fingerprintSHA256: fingerprint
        )

        try KeychainHelper.save(data: privateKey.rawRepresentation, account: pair.keychainAccount)
        keys.append(pair)
        try storageService.saveSSHKeys(keys)
        return pair
    }

    /// Importa uma chave privada Ed25519 em formato OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`)
    /// ou semente raw em Base64 (32 bytes).
    public func importPrivateKey(name: String, pemOrBase64: String) throws -> SSHKeyPair {
        let trimmed = pemOrBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey: Curve25519.Signing.PrivateKey

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            let rawSeed = try parseUnencryptedOpenSSHEd25519Seed(from: trimmed)
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawSeed)
        } else if let decoded = Data(base64Encoded: trimmed), decoded.count == 32 {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: decoded)
        } else {
            throw AppError.sshKeyParseFailed("Forneça uma chave OpenSSH Ed25519 não criptografada ou seed Base64 de 32 bytes.")
        }

        let openSSHBlob = buildOpenSSHEd25519Blob(publicKeyRaw: privateKey.publicKey.rawRepresentation)
        let openSSHPublic = "ssh-ed25519 \(openSSHBlob.base64EncodedString()) \(name.replacingOccurrences(of: " ", with: "_"))"
        let fingerprint = "SHA256:\(SHA256.hash(data: openSSHBlob).withUnsafeBytes { Data($0).base64EncodedString().replacingOccurrences(of: "=", with: "") })"

        let pair = SSHKeyPair(
            name: name,
            algorithm: .ed25519,
            publicKeyOpenSSH: openSSHPublic,
            fingerprintSHA256: fingerprint
        )

        try KeychainHelper.save(data: privateKey.rawRepresentation, account: pair.keychainAccount)
        keys.append(pair)
        try storageService.saveSSHKeys(keys)
        return pair
    }

    public func exportOpenSSHPrivateKeyPEM(for key: SSHKeyPair) throws -> String {
        guard let seed = KeychainHelper.load(account: key.keychainAccount) else {
            throw AppError.fileNotFound("Chave privada não encontrada no Keychain.")
        }
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return encodeUnencryptedOpenSSHEd25519PEM(privateKey: priv, comment: key.name)
    }

    public func deleteKey(id: UUID) throws {
        if let key = keys.first(where: { $0.id == id }) {
            KeychainHelper.delete(account: key.keychainAccount)
        }
        keys.removeAll { $0.id == id }
        try storageService.saveSSHKeys(keys)
    }

    // MARK: - Conexões & Abas Múltiplas

    @discardableResult
    public func openSession(profile: SSHHostProfile, passwordOverride: String? = nil) -> SSHSessionTab {
        let tab = SSHSessionTab(profile: profile)
        tabs.append(tab)
        selectedTabId = tab.id

        connectTab(tab, passwordOverride: passwordOverride)
        return tab
    }

    public func reconnectTab(_ tab: SSHSessionTab, passwordOverride: String? = nil) {
        tab.closeSession()
        connectTab(tab, passwordOverride: passwordOverride)
    }

    public func closeTab(id: UUID) {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].closeSession()
            tabs.remove(at: index)
            if selectedTabId == id {
                selectedTabId = tabs.last?.id
            }
        }
    }

    private func connectTab(_ tab: SSHSessionTab, passwordOverride: String?) {
        let profile = tab.profile
        tab.state = .connecting
        tab.appendOutput(Data("Conectando a \(profile.username)@\(profile.host):\(profile.port)...\r\n".utf8))

        tab.sessionTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let authMethod = try self.buildAuthMethod(for: profile, passwordOverride: passwordOverride)
                let settings = SSHClientSettings(
                    host: profile.host,
                    port: Int(profile.port),
                    authenticationMethod: { authMethod },
                    hostKeyValidator: .acceptAnything()
                )

                let client = try await SSHClient.connect(to: settings)
                tab.client = client
                tab.state = .connected

                if let idx = self.savedHosts.firstIndex(where: { $0.id == profile.id }) {
                    self.savedHosts[idx].lastConnectedAt = Date()
                    try? self.storageService.saveSSHHosts(self.savedHosts)
                }

                let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: tab.cols,
                    terminalRowHeight: tab.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )

                try await client.withPTY(ptyRequest) { ttyOutput, ttyStdinWriter in
                    tab.stdinWriter = ttyStdinWriter
                    for try await event in ttyOutput {
                        switch event {
                        case .stdout(let buffer):
                            let bytes = buffer.readableBytesView
                            tab.appendOutput(Data(bytes))
                        case .stderr(let buffer):
                            let bytes = buffer.readableBytesView
                            tab.appendOutput(Data(bytes))
                        }
                    }
                }

                if !Task.isCancelled {
                    tab.appendOutput(Data("\r\n[Sessão SSH encerrada pelo servidor]\r\n".utf8))
                    tab.state = .disconnected
                }
            } catch is CancellationError {
                tab.state = .disconnected
            } catch {
                let message = error.localizedDescription
                tab.appendOutput(Data("\r\n[Erro SSH] \(message)\r\n".utf8))
                tab.state = .error(message)
            }
        }
    }

    private func buildAuthMethod(for profile: SSHHostProfile, passwordOverride: String?) throws -> SSHAuthenticationMethod {
        switch profile.authType {
        case .password:
            let pass = passwordOverride ?? loadPassword(for: profile.id) ?? ""
            return .passwordBased(username: profile.username, password: pass)
        case .privateKey:
            guard let keyId = profile.keyId,
                  let keyPair = keys.first(where: { $0.id == keyId }),
                  let seed = KeychainHelper.load(account: keyPair.keychainAccount) else {
                throw AppError.sshAuthenticationFailed("Nenhuma chave SSH válida selecionada para este host.")
            }
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return .ed25519(username: profile.username, privateKey: privateKey)
        }
    }

    // MARK: - OpenSSH Wire Format Helpers (Ed25519)

    private func buildOpenSSHEd25519Blob(publicKeyRaw: Data) -> Data {
        var blob = Data()
        appendSSHString("ssh-ed25519", to: &blob)
        appendSSHData(publicKeyRaw, to: &blob)
        return blob
    }

    private func appendSSHString(_ value: String, to data: inout Data) {
        appendSSHData(Data(value.utf8), to: &data)
    }

    private func appendSSHData(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(value)
    }

    private func parseUnencryptedOpenSSHEd25519Seed(from pem: String) throws -> Data {
        let lines = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let raw = Data(base64Encoded: lines.joined()) else {
            throw AppError.sshKeyParseFailed("Base64 inválido na chave OpenSSH.")
        }

        let magic = Data("openssh-key-v1\0".utf8)
        guard raw.starts(with: magic) else {
            throw AppError.sshKeyParseFailed("Cabeçalho 'openssh-key-v1' ausente.")
        }

        var cursor = magic.count

        func readBytes() throws -> Data {
            guard cursor + 4 <= raw.count else {
                throw AppError.sshKeyParseFailed("Container OpenSSH truncado.")
            }
            let len = raw.subdata(in: cursor..<(cursor + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            cursor += 4
            let end = cursor + Int(len)
            guard end <= raw.count else {
                throw AppError.sshKeyParseFailed("Tamanho de campo inválido na chave OpenSSH.")
            }
            let slice = raw.subdata(in: cursor..<end)
            cursor = end
            return slice
        }

        let cipherName = String(data: try readBytes(), encoding: .utf8)
        let _ = try readBytes() // kdfname
        let _ = try readBytes() // kdfoptions
        guard cipherName == "none" else {
            throw AppError.sshKeyParseFailed("Chaves protegidas por passphrase ('\(cipherName ?? "")') ainda não são suportadas; importe uma chave sem senha.")
        }

        guard cursor + 4 <= raw.count else { throw AppError.sshKeyParseFailed("Contador de chaves ausente.") }
        cursor += 4 // number of keys
        let _ = try readBytes() // public key blob
        let privBlock = try readBytes()

        // Dentro de privBlock: checkint1(4) + checkint2(4) + keytype + pub(32) + priv+pub(64)
        var pCursor = 8
        func readPrivBytes() throws -> Data {
            guard pCursor + 4 <= privBlock.count else {
                throw AppError.sshKeyParseFailed("Bloco privado truncado.")
            }
            let len = privBlock.subdata(in: pCursor..<(pCursor + 4)).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            pCursor += 4
            let end = pCursor + Int(len)
            guard end <= privBlock.count else {
                throw AppError.sshKeyParseFailed("Tamanho de chave privada inválido.")
            }
            let slice = privBlock.subdata(in: pCursor..<end)
            pCursor = end
            return slice
        }

        let keyType = String(data: try readPrivBytes(), encoding: .utf8)
        guard keyType == "ssh-ed25519" else {
            throw AppError.sshKeyParseFailed("Somente chaves 'ssh-ed25519' são suportadas no importador PEM (\(keyType ?? "desconhecido")).")
        }
        let _ = try readPrivBytes() // pubkey (32 bytes)
        let privPlusPub = try readPrivBytes() // 64 bytes: primeiros 32 são a seed privada
        guard privPlusPub.count >= 32 else {
            throw AppError.sshKeyParseFailed("Seed Ed25519 inválida.")
        }
        return privPlusPub.prefix(32)
    }

    private func encodeUnencryptedOpenSSHEd25519PEM(privateKey: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let pub = privateKey.publicKey.rawRepresentation
        let priv = privateKey.rawRepresentation

        let pubBlob = buildOpenSSHEd25519Blob(publicKeyRaw: pub)

        var privSection = Data()
        let checkInt = UInt32.random(in: 1...UInt32.max).bigEndian
        withUnsafeBytes(of: checkInt) { privSection.append(contentsOf: $0) }
        withUnsafeBytes(of: checkInt) { privSection.append(contentsOf: $0) }
        appendSSHString("ssh-ed25519", to: &privSection)
        appendSSHData(pub, to: &privSection)
        appendSSHData(priv + pub, to: &privSection)
        appendSSHString(comment, to: &privSection)

        var padByte: UInt8 = 1
        while privSection.count % 8 != 0 {
            privSection.append(padByte)
            padByte &+= 1
        }

        var container = Data("openssh-key-v1\0".utf8)
        appendSSHString("none", to: &container)
        appendSSHString("none", to: &container)
        appendSSHData(Data(), to: &container)
        var numKeys = UInt32(1).bigEndian
        container.append(Data(bytes: &numKeys, count: 4))
        appendSSHData(pubBlob, to: &container)
        appendSSHData(privSection, to: &container)

        let b64 = container.base64EncodedString()
        var lines: [String] = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = b64.startIndex
        while index < b64.endIndex {
            let next = b64.index(index, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[index..<next]))
            index = next
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n")
    }
}

