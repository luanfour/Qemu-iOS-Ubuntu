import Foundation

/// Backend de diagnóstico e simulação interativa usado automaticamente quando
/// o framework binário `libqemu.xcframework` ainda não foi compilado e linkado ao app.
/// Permite testar todo o fluxo do app no dispositivo: ciclo de vida da VM,
/// console serial interativa (SwiftTerm), edição de linha de comando, pause/resume e telemetria.
public final class SimulatedQEMUBackend: QEMUBackend, @unchecked Sendable {
    public let backendDisplayName = "Modo Diagnóstico TCI (Sem libqemu.xcframework)"
    public let isHardwareOrTCIVirtualizationReal = false

    public let events: AsyncStream<QEMUBackendEvent>
    private let continuation: AsyncStream<QEMUBackendEvent>.Continuation

    private final class SimulatedSession {
        let context: QEMUStartContext
        var isPaused: Bool = false
        var lineBuffer: String = ""
        var currentDirectory: String = "/home/ubuntu"
        var loopTask: Task<Void, Never>?

        init(context: QEMUStartContext) {
            self.context = context
        }
    }

    private let lock = NSLock()
    private var sessions: [UUID: SimulatedSession] = [:]

    public init() {
        var captured: AsyncStream<QEMUBackendEvent>.Continuation!
        self.events = AsyncStream { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    deinit {
        continuation.finish()
    }

    public func startVM(context: QEMUStartContext) async throws {
        let vmId = context.vm.id

        lock.lock()
        let exists = sessions[vmId] != nil
        lock.unlock()
        if exists {
            throw AppError.vmAlreadyRunning(context.vm.name)
        }

        let session = SimulatedSession(context: context)
        lock.lock()
        sessions[vmId] = session
        lock.unlock()

        continuation.yield(.stateChanged(vmId, .starting))
        emitText(vmId, "\u{001B}[2J\u{001B}[H")
        emitText(vmId, "\u{001B}[1;33m[Qemu-ios-ubuntu :: Modo Diagnóstico]\u{001B}[0m\r\n")
        emitText(vmId, "libqemu.xcframework não detectado no bundle; executando console serial simulada.\r\n")
        emitText(vmId, "Para virtualização real de ISOs Ubuntu Server, integre o libqemu.xcframework (veja README.md).\r\n\r\n")
        emitText(vmId, "\u{001B}[36mComando QEMU equivalente:\u{001B}[0m\r\n")
        emitText(vmId, "\(context.arguments.joined(separator: " "))\r\n\r\n")

        try? await Task.sleep(nanoseconds: 300_000_000)

        let modeLabel = context.useJIT ? "TCG JIT (CS_DEBUGGED ativo)" : "TCI Interpretado (sem JIT — estilo UTM SE)"
        emitText(vmId, "[    0.000000] Booting Linux on \(context.vm.architecture.rawValue) (\(modeLabel))\r\n")
        emitText(vmId, "[    0.214012] Memory: \(context.vm.ramMB)MB | SMP: \(context.vm.cpuCores) vCPUs\r\n")
        emitText(vmId, "[    0.492300] virtio_blk: \(context.diskPath) (qcow2, \(context.vm.diskSizeGB)GB)\r\n")
        if let iso = context.isoPath {
            emitText(vmId, "[    0.610884] sr0: ISO anexada em \(URL(fileURLWithPath: iso).lastPathComponent)\r\n")
        }
        let ports = context.vm.portForwards.map { "\($0.hostPort)->\($0.guestPort)/\($0.transport.rawValue)" }.joined(separator: ", ")
        emitText(vmId, "[    0.850112] virtio_net: NAT ativo [\(ports.isEmpty ? "sem portas" : ports)]\r\n")
        emitText(vmId, "\r\nUbuntu 24.04.1 LTS \(sanitizedHostname(context.vm.name)) ttyAMA0\r\n\r\n")
        emitText(vmId, "Digite 'help' para comandos de diagnóstico do console serial.\r\n")
        emitPrompt(session)

        continuation.yield(.stateChanged(vmId, .running))

        session.loopTask = Task.detached(priority: .utility) { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                let paused = self.lock.withLock { self.sessions[vmId]?.isPaused ?? true }
                if !paused {
                    tick += 1
                    let cpu = 8.0 + Double((tick * 7) % 18)
                    let ram = min(Double(context.vm.ramMB), Double(context.vm.ramMB) * 0.32 + Double(tick % 24))
                    self.continuation.yield(.telemetrySample(vmId, cpuPercent: cpu, memoryMB: ram))
                }
            }
        }
    }

    public func pauseVM(id: UUID) async throws {
        let session = try requireSession(id)
        session.isPaused = true
        emitText(id, "\r\n\u{001B}[33m[QMP] VM pausada (CPU suspensa).\u{001B}[0m\r\n")
        continuation.yield(.stateChanged(id, .paused))
    }

    public func resumeVM(id: UUID) async throws {
        let session = try requireSession(id)
        session.isPaused = false
        emitText(id, "\r\n\u{001B}[32m[QMP] VM retomada.\u{001B}[0m\r\n")
        emitPrompt(session)
        continuation.yield(.stateChanged(id, .running))
    }

    public func stopVM(id: UUID, force: Bool) async throws {
        let session = try requireSession(id)
        continuation.yield(.stateChanged(id, .stopping))
        if !force {
            emitText(id, "\r\n[ACPI] Power button pressed. Shutting down Ubuntu Server...\r\n")
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        session.loopTask?.cancel()
        lock.withLock {
            _ = sessions.removeValue(forKey: id)
        }
        emitText(id, "[QEMU] VM encerrada.\r\n")
        continuation.yield(.exited(id, code: 0))
        continuation.yield(.stateChanged(id, .stopped))
    }

    public func resetVM(id: UUID) async throws {
        let session = try requireSession(id)
        emitText(id, "\r\n\u{001B}[36m[QMP] system_reset executado...\u{001B}[0m\r\n")
        emitPrompt(session)
    }

    public func saveVMSnapshot(id: UUID, tag: String) async throws {
        _ = try requireSession(id)
        emitText(id, "\r\n\u{001B}[32m[QMP] Snapshot '\(tag)' salvo no modo diagnóstico.\u{001B}[0m\r\n")
    }

    public func sendSerialInput(_ data: Data, to vmId: UUID) async throws {
        let session = try requireSession(vmId)
        guard !session.isPaused else { return }
        guard let input = String(data: data, encoding: .utf8) else { return }

        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 3: // Ctrl+C
                session.lineBuffer = ""
                emitText(vmId, "^C\r\n")
                emitPrompt(session)
            case 12: // Ctrl+L
                emitText(vmId, "\u{001B}[2J\u{001B}[H")
                emitPrompt(session)
                emitText(vmId, session.lineBuffer)
            case 13, 10: // Enter
                let command = session.lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                session.lineBuffer = ""
                emitText(vmId, "\r\n")
                handleSimulatedCommand(command, session: session)
            case 127, 8: // Backspace
                if !session.lineBuffer.isEmpty {
                    session.lineBuffer.removeLast()
                    emitText(vmId, "\u{0008} \u{0008}")
                }
            default:
                if scalar.value >= 32 {
                    let ch = String(scalar)
                    session.lineBuffer.append(ch)
                    emitText(vmId, ch)
                }
            }
        }
    }

    // MARK: - Interpretador leve de diagnóstico

    private func handleSimulatedCommand(_ command: String, session: SimulatedSession) {
        let vmId = session.context.vm.id
        switch command {
        case "":
            break
        case "help":
            emitText(vmId, "Comandos disponíveis (Modo Diagnóstico):\r\n")
            emitText(vmId, "  uname -a   Exibe arquitetura e modo TCG/JIT\r\n")
            emitText(vmId, "  free -m    Exibe RAM configurada para a VM\r\n")
            emitText(vmId, "  ip a       Exibe rede NAT e portas encaminhadas\r\n")
            emitText(vmId, "  qemu-cmd   Mostra a linha de comando QEMU gerada\r\n")
            emitText(vmId, "  clear      Limpa a tela do terminal\r\n")
            emitText(vmId, "  poweroff   Encerra a VM\r\n")
        case "uname", "uname -a":
            let arch = session.context.vm.architecture.rawValue
            emitText(vmId, "Linux \(sanitizedHostname(session.context.vm.name)) 6.8.0-ubuntu-server #1 SMP \(arch) GNU/Linux\r\n")
        case "free", "free -m":
            let total = session.context.vm.ramMB
            let used = Int(Double(total) * 0.34)
            emitText(vmId, "               total        used        free\r\n")
            emitText(vmId, String(format: "Mem:           %5d       %5d       %5d\r\n", total, used, total - used))
        case "ip a", "ip addr":
            emitText(vmId, "1: lo: <LOOPBACK,UP> inet 127.0.0.1/8\r\n")
            emitText(vmId, "2: eth0: <UP> inet 10.0.2.15/24 (QEMU User NAT)\r\n")
            for rule in session.context.vm.portForwards {
                emitText(vmId, "   hostfwd \(rule.transport.rawValue): 127.0.0.1:\(rule.hostPort) -> 10.0.2.15:\(rule.guestPort) (\(rule.name))\r\n")
            }
        case "qemu-cmd":
            emitText(vmId, "\(session.context.arguments.joined(separator: " "))\r\n")
        case "clear":
            emitText(vmId, "\u{001B}[2J\u{001B}[H")
        case "poweroff", "exit":
            Task {
                try? await self.stopVM(id: vmId, force: false)
            }
            return
        default:
            emitText(vmId, "bash: \(command): comando não encontrado no modo diagnóstico (digite 'help')\r\n")
        }
        emitPrompt(session)
    }

    private func requireSession(_ id: UUID) throws -> SimulatedSession {
        guard let session = lock.withLock({ sessions[id] }) else {
            throw AppError.vmNotRunning(id.uuidString)
        }
        return session
    }

    private func emitText(_ vmId: UUID, _ text: String) {
        if let data = text.data(using: .utf8) {
            continuation.yield(.serialData(vmId, data))
        }
    }

    private func emitPrompt(_ session: SimulatedSession) {
        let host = sanitizedHostname(session.context.vm.name)
        emitText(session.context.vm.id, "\u{001B}[1;32mubuntu@\(host)\u{001B}[0m:\u{001B}[1;34m~\u{001B}[0m$ ")
    }

    private func sanitizedHostname(_ name: String) -> String {
        let cleaned = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? "ubuntu-vm" : cleaned
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

