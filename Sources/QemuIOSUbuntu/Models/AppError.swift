import Foundation

/// Erros estruturados de domínio para toda a aplicação Qemu-ios-ubuntu.
/// Permite exibir mensagens amigáveis e ações corretivas diretamente na interface.
public enum AppError: LocalizedError, Sendable, Equatable {
    // Erros de armazenamento e arquivos
    case isoInvalidSignature(String)
    case isoImportFailed(String)
    case diskCreationFailed(String)
    case storageInsufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case snapshotOperationFailed(String)
    case exportImportFailed(String)
    case fileNotFound(String)

    // Erros do motor QEMU
    case vmAlreadyRunning(String)
    case vmNotRunning(String)
    case vmConfigurationInvalid(String)
    case qemuBackendUnavailable(String)
    case qemuExecutionFailed(code: Int32, reason: String)
    case qmpCommunicationFailed(String)

    // Erros de SSH e chaves
    case sshConnectionFailed(String)
    case sshAuthenticationFailed(String)
    case sshKeyGenerationFailed(String)
    case sshKeyParseFailed(String)
    case keychainError(OSStatus)

    // Erros de VNC / Background
    case vncConnectionFailed(String)
    case backgroundAudioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .isoInvalidSignature(let name):
            return "O arquivo '\(name)' não parece ser uma imagem ISO 9660 válida."
        case .isoImportFailed(let detail):
            return "Falha ao importar a ISO: \(detail)"
        case .diskCreationFailed(let detail):
            return "Não foi possível criar o disco virtual QCOW2: \(detail)"
        case .storageInsufficientSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Espaço insuficiente no dispositivo. Necessário: \(reqStr), disponível: \(availStr)."
        case .snapshotOperationFailed(let detail):
            return "Erro na operação de snapshot: \(detail)"
        case .exportImportFailed(let detail):
            return "Falha ao exportar/importar pacote de VM: \(detail)"
        case .fileNotFound(let path):
            return "Arquivo não encontrado: \(path)"
        case .vmAlreadyRunning(let name):
            return "A máquina virtual '\(name)' já está em execução."
        case .vmNotRunning(let name):
            return "A máquina virtual '\(name)' não está em execução."
        case .vmConfigurationInvalid(let detail):
            return "Configuração de VM inválida: \(detail)"
        case .qemuBackendUnavailable(let detail):
            return "Backend QEMU indisponível: \(detail)"
        case .qemuExecutionFailed(let code, let reason):
            return "QEMU encerrou com código \(code): \(reason)"
        case .qmpCommunicationFailed(let detail):
            return "Falha na comunicação QMP: \(detail)"
        case .sshConnectionFailed(let detail):
            return "Não foi possível conectar via SSH: \(detail)"
        case .sshAuthenticationFailed(let detail):
            return "Falha na autenticação SSH: \(detail)"
        case .sshKeyGenerationFailed(let detail):
            return "Erro ao gerar par de chaves SSH: \(detail)"
        case .sshKeyParseFailed(let detail):
            return "Formato de chave SSH inválido ou não suportado: \(detail)"
        case .keychainError(let status):
            return "Erro no Keychain do iOS (OSStatus \(status))."
        case .vncConnectionFailed(let detail):
            return "Falha na conexão VNC: \(detail)"
        case .backgroundAudioFailed(let detail):
            return "Não foi possível ativar áudio silencioso em segundo plano: \(detail)"
        }
    }
}

