import Foundation
import SwiftUI
import UIKit

/// ViewModel da aba "SSH": coordena hosts salvos, abas múltiplas, chaves SSH e conexão rápida com VMs locais.
@MainActor
public final class SSHViewModel: ObservableObject {
    @Published public var isPresentingHostEditor: Bool = false
    @Published public var editingHost: SSHHostProfile?
    @Published public var isPresentingKeyManager: Bool = false
    @Published public var errorMessage: String?
    @Published public var ctrlActive: Bool = false
    @Published public var altActive: Bool = false
    @Published public var fontSize: CGFloat = 13

    public let sshService: SSHService

    public init(sshService: SSHService) {
        self.sshService = sshService
    }

    public func connect(to profile: SSHHostProfile, passwordOverride: String? = nil) {
        sshService.openSession(profile: profile, passwordOverride: passwordOverride)
    }

    /// Abre conexão SSH direta para `127.0.0.1:<hostPort>` de uma VM Ubuntu em execução.
    public func quickConnectToVM(_ vm: VirtualMachine, username: String = "ubuntu", password: String? = nil) {
        let port = vm.sshHostPort ?? 2222
        if let existing = sshService.savedHosts.first(where: { $0.linkedVMId == vm.id || ($0.host == "127.0.0.1" && $0.port == port) }) {
            sshService.openSession(profile: existing, passwordOverride: password)
            return
        }

        let profile = SSHHostProfile(
            name: "\(vm.name) (Local)",
            host: "127.0.0.1",
            port: port,
            username: username,
            authType: .password,
            linkedVMId: vm.id
        )
        try? sshService.upsertHost(profile)
        sshService.openSession(profile: profile, passwordOverride: password)
    }

    public func saveHost(_ profile: SSHHostProfile, password: String?) {
        do {
            try sshService.upsertHost(profile)
            if profile.authType == .password, let password, !password.isEmpty {
                try sshService.savePassword(password, for: profile.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteHost(id: UUID) {
        do {
            try sshService.deleteHost(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func handleTabSend(bytes: ArraySlice<UInt8>, tab: SSHSessionTab) {
        var payload = Array(bytes)
        if ctrlActive, let first = payload.first {
            let upper = first >= 97 && first <= 122 ? first - 32 : first
            if upper >= 64 && upper <= 95 {
                payload[0] = upper - 64
            }
            ctrlActive = false
        } else if altActive, !payload.isEmpty {
            payload.insert(0x1B, at: 0)
            altActive = false
        }
        tab.sendBytes(payload)
    }

    public func pasteClipboard(to tab: SSHSessionTab) {
        if let text = UIPasteboard.general.string, let data = text.data(using: .utf8) {
            tab.sendBytes([UInt8](data))
        }
    }
}

