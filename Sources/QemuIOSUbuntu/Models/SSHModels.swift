import Foundation

/// Método de autenticação suportado pelo cliente SSH integrado (Citadel).
public enum SSHAuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password = "password"
    case privateKey = "privateKey"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .password: return "Senha"
        case .privateKey: return "Chave SSH (Ed25519 / PEM)"
        }
    }
}

/// Par de chaves SSH gerenciado pelo app (chave privada guardada no Keychain).
public struct SSHKeyPair: Codable, Identifiable, Hashable, Sendable {
    public enum KeyAlgorithm: String, Codable, CaseIterable, Sendable {
        case ed25519 = "ssh-ed25519"
        case ecdsaP256 = "ecdsa-sha2-nistp256"
    }

    public var id: UUID
    public var name: String
    public var algorithm: KeyAlgorithm
    public var publicKeyOpenSSH: String
    public var fingerprintSHA256: String
    public var keychainAccount: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        algorithm: KeyAlgorithm = .ed25519,
        publicKeyOpenSSH: String,
        fingerprintSHA256: String,
        keychainAccount: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.keychainAccount = keychainAccount ?? "sshkey-\(id.uuidString)"
        self.createdAt = createdAt
    }
}

/// Perfil de host SSH salvo pelo usuário (VM local ou servidor remoto).
public struct SSHHostProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authType: SSHAuthType
    public var keyId: UUID?
    public var linkedVMId: UUID?
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String = "127.0.0.1",
        port: UInt16 = 2222,
        username: String = "ubuntu",
        authType: SSHAuthType = .password,
        keyId: UUID? = nil,
        linkedVMId: UUID? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.keyId = keyId
        self.linkedVMId = linkedVMId
        self.lastConnectedAt = lastConnectedAt
    }
}

/// Estado de conexão de uma aba SSH ativa.
public enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .disconnected: return "Desconectado"
        case .connecting: return "Conectando..."
        case .connected: return "Conectado"
        case .error(let msg): return "Erro: \(msg)"
        }
    }
}

