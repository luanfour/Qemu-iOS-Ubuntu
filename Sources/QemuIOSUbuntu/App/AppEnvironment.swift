import Foundation

/// Contêiner de injeção de dependências compartilhado por toda a árvore SwiftUI.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let storageService: StorageService
    public let backgroundService: BackgroundServerService
    public let qemuService: QEMUService
    public let terminalService: TerminalService
    public let sshService: SSHService
    public let vncService: VNCClientService

    public let vmManagerVM: VMManagerViewModel
    public let terminalVM: TerminalViewModel
    public let sshVM: SSHViewModel
    public let settingsVM: SettingsStorageViewModel

    public init() {
        let storage = StorageService()
        let background = BackgroundServerService()
        let qemu = QEMUService(storageService: storage, backgroundService: background)
        let terminal = TerminalService()
        terminal.bind(to: qemu)

        let ssh = SSHService(storageService: storage)
        let vnc = VNCClientService()

        self.storageService = storage
        self.backgroundService = background
        self.qemuService = qemu
        self.terminalService = terminal
        self.sshService = ssh
        self.vncService = vnc

        self.vmManagerVM = VMManagerViewModel(storageService: storage, qemuService: qemu)
        self.terminalVM = TerminalViewModel(terminalService: terminal)
        self.sshVM = SSHViewModel(sshService: ssh)
        self.settingsVM = SettingsStorageViewModel(storageService: storage)
    }
}

