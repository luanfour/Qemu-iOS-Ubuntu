import Foundation
import SwiftUI
import UIKit

/// ViewModel da aba "Terminal": controla qual console serial da VM está exibida,
/// estado do modificador Ctrl/Alt da barra acessória e tamanho da fonte.
@MainActor
public final class TerminalViewModel: ObservableObject {
    @Published public var selectedVMId: UUID?
    @Published public var ctrlActive: Bool = false
    @Published public var altActive: Bool = false
    @Published public var fontSize: CGFloat = 13

    private let terminalService: TerminalService

    public init(terminalService: TerminalService) {
        self.terminalService = terminalService
    }

    /// Processa teclas digitadas no SwiftTerm aplicando modificadores Ctrl/Alt da barra acessória quando ativos.
    public func handleTerminalSend(bytes: ArraySlice<UInt8>, for vmId: UUID) {
        var payload = Array(bytes)

        if ctrlActive, let first = payload.first {
            // Mapeia 'a'..'z' ou 'A'..'Z' para códigos de controle ASCII 0x01..0x1A
            let upper = first >= 97 && first <= 122 ? first - 32 : first
            if upper >= 64 && upper <= 95 {
                payload[0] = upper - 64
            }
            ctrlActive = false
        } else if altActive, !payload.isEmpty {
            payload.insert(0x1B, at: 0) // Prefixo ESC para Meta/Alt
            altActive = false
        }

        terminalService.sendBytes(payload, to: vmId)
    }

    public func sendSpecialSequence(_ bytes: [UInt8], to vmId: UUID) {
        terminalService.sendBytes(bytes, to: vmId)
    }

    public func pasteFromClipboard(to vmId: UUID) {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            terminalService.sendText(text, to: vmId)
        }
    }

    public func clearTerminal(for vmId: UUID) {
        terminalService.clearBuffer(for: vmId)
    }
}

