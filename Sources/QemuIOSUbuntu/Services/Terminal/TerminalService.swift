import Foundation
import SwiftTerm

/// Gerencia os buffers de console serial e o roteamento entre o `QEMUService` e os controles `SwiftTerm.TerminalView`.
@MainActor
public final class TerminalService: ObservableObject {
    /// Armazena o histórico recente de bytes por VM (até ~256 KiB por VM) para preservar scrollback ao trocar de aba.
    private var buffersByVM: [UUID: Data] = [:]
    private let maxBufferBytes = 256 * 1024

    /// Referências fracas para os TerminalViews ativos vinculados a cada VM.
    private var attachedViews: [UUID: WeakTerminalBox] = [:]

    private weak var qemuService: QEMUService?

    public init() {}

    public func bind(to qemuService: QEMUService) {
        self.qemuService = qemuService
        qemuService.onSerialDataReceived = { [weak self] vmId, data in
            Task { @MainActor in
                self?.appendSerialOutput(data, for: vmId)
            }
        }
    }

    /// Registra a `TerminalView` de uma VM e reproduz o histórico acumulado imediatamente.
    public func attach(terminalView: TerminalView, to vmId: UUID) {
        attachedViews[vmId] = WeakTerminalBox(view: terminalView)
        if let existing = buffersByVM[vmId], !existing.isEmpty {
            let bytes = [UInt8](existing)
            terminalView.feed(byteArray: ArraySlice(bytes))
        }
    }

    public func detach(vmId: UUID) {
        attachedViews.removeValue(forKey: vmId)
    }

    public func appendSerialOutput(_ data: Data, for vmId: UUID) {
        var buffer = buffersByVM[vmId] ?? Data()
        buffer.append(data)
        if buffer.count > maxBufferBytes {
            buffer.removeFirst(buffer.count - maxBufferBytes)
        }
        buffersByVM[vmId] = buffer

        if let view = attachedViews[vmId]?.view {
            let bytes = [UInt8](data)
            view.feed(byteArray: ArraySlice(bytes))
        }
    }

    public func sendBytes(_ bytes: [UInt8], to vmId: UUID) {
        let data = Data(bytes)
        Task {
            try? await qemuService?.sendSerialInput(data, to: vmId)
        }
    }

    public func sendText(_ text: String, to vmId: UUID) {
        guard let data = text.data(using: .utf8) else { return }
        Task {
            try? await qemuService?.sendSerialInput(data, to: vmId)
        }
    }

    public func clearBuffer(for vmId: UUID) {
        buffersByVM[vmId] = Data()
        if let view = attachedViews[vmId]?.view {
            let resetSeq: [UInt8] = Array("\u{001B}[2J\u{001B}[H".utf8)
            view.feed(byteArray: ArraySlice(resetSeq))
        }
    }

    private final class WeakTerminalBox {
        weak var view: TerminalView?
        init(view: TerminalView) {
            self.view = view
        }
    }
}

