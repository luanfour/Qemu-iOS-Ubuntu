import Darwin
import Foundation
import Network
import QEMUBridge

/// Implementação real de `QEMUBackend` que integra o binário/framework `libqemu.xcframework`
/// (compilado com `--enable-tcg-interpreter` ao estilo UTM SE) rodando em pthread dedicada.
/// A comunicação de controle é feita via QMP (Unix Domain Socket) e a console serial via TCP loopback.
public final class EmbeddedQEMUBackend: QEMUBackend, @unchecked Sendable {
    public let backendDisplayName = "QEMU Embarcado (libqemu + QMP)"
    public let isHardwareOrTCIVirtualizationReal = true

    public let events: AsyncStream<QEMUBackendEvent>
    private let continuation: AsyncStream<QEMUBackendEvent>.Continuation

    private final class ActiveSession {
        let vmId: UUID
        let qmpSocketPath: String
        let serialPort: UInt16
        var serialConnection: NWConnection?
        var qmpFileDescriptor: Int32 = -1
        var telemetryTask: Task<Void, Never>?
        var isPaused: Bool = false

        init(vmId: UUID, qmpSocketPath: String, serialPort: UInt16) {
            self.vmId = vmId
            self.qmpSocketPath = qmpSocketPath
            self.serialPort = serialPort
        }
    }

    private let lock = NSLock()
    private var sessions: [UUID: ActiveSession] = [:]

    public init() {
        var capturedContinuation: AsyncStream<QEMUBackendEvent>.Continuation!
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    deinit {
        continuation.finish()
    }

    public func startVM(context: QEMUStartContext) async throws {
        let vmId = context.vm.id
        let arch = context.vm.architecture.rawValue

        guard qemu_bridge_is_libqemu_available(arch) else {
            throw AppError.qemuBackendUnavailable(
                "Símbolo libqemu para \(arch) não encontrado no binário. Consulte o README para adicionar o libqemu.xcframework."
            )
        }

        lock.lock()
        let alreadyRunning = sessions[vmId] != nil
        lock.unlock()
        if alreadyRunning {
            throw AppError.vmAlreadyRunning(context.vm.name)
        }

        // Remove socket QMP residual antes de iniciar
        unlink(context.qmpSocketPath)

        continuation.yield(.stateChanged(vmId, .starting))
        continuation.yield(.logMessage(vmId, "[QEMU] Iniciando \(context.arguments.joined(separator: " "))"))

        let session = ActiveSession(
            vmId: vmId,
            qmpSocketPath: context.qmpSocketPath,
            serialPort: context.serialTCPPort
        )

        lock.lock()
        sessions[vmId] = session
        lock.unlock()

        // Prepara ponteiros C para passar à ponte C (`qemu_bridge_launch_embedded`)
        let contextBox = Unmanaged.passRetained(CallbackBox(vmId: vmId, backend: self)).toOpaque()
        let launchResult = withCStringArray(context.arguments) { cStrings in
            arch.withCString { cArch in
                qemu_bridge_launch_embedded(
                    cArch,
                    Int32(context.arguments.count),
                    cStrings,
                    { exitCode, rawContext in
                        guard let rawContext else { return }
                        let box = Unmanaged<CallbackBox>.fromOpaque(rawContext).takeRetainedValue()
                        box.backend?.handleQEMUProcessExit(vmId: box.vmId, exitCode: exitCode)
                    },
                    contextBox
                )
            }
        }

        if launchResult != 0 {
            _ = Unmanaged<CallbackBox>.fromOpaque(contextBox).takeRetainedValue()
            cleanupSession(vmId: vmId)
            continuation.yield(.stateChanged(vmId, .error))
            throw AppError.qemuExecutionFailed(code: launchResult, reason: "Falha ao criar thread do QEMU (pthread erro \(launchResult)).")
        }

        // Aguarda socket serial e QMP ficarem prontos em segundo plano
        try await connectSerialSocket(for: session)
        try? await connectQMPSocket(for: session)
        startTelemetryLoop(for: session, maxRAMMB: Double(context.vm.ramMB))

        continuation.yield(.stateChanged(vmId, .running))
    }

    public func pauseVM(id: UUID) async throws {
        guard let session = session(for: id) else {
            throw AppError.vmNotRunning(id.uuidString)
        }
        try await sendQMPCommand(session: session, command: #"{"execute":"stop"}"#)
        session.isPaused = true
        continuation.yield(.stateChanged(id, .paused))
    }

    public func resumeVM(id: UUID) async throws {
        guard let session = session(for: id) else {
            throw AppError.vmNotRunning(id.uuidString)
        }
        try await sendQMPCommand(session: session, command: #"{"execute":"cont"}"#)
        session.isPaused = false
        continuation.yield(.stateChanged(id, .running))
    }

    public func stopVM(id: UUID, force: Bool) async throws {
        guard let session = session(for: id) else {
            throw AppError.vmNotRunning(id.uuidString)
        }
        continuation.yield(.stateChanged(id, .stopping))
        let cmd = force ? #"{"execute":"quit"}"# : #"{"execute":"system_powerdown"}"#
        do {
            try await sendQMPCommand(session: session, command: cmd)
        } catch {
            if force {
                cleanupSession(vmId: id)
                continuation.yield(.stateChanged(id, .stopped))
                return
            }
            throw error
        }
        if force {
            cleanupSession(vmId: id)
            continuation.yield(.stateChanged(id, .stopped))
        }
    }

    public func resetVM(id: UUID) async throws {
        guard let session = session(for: id) else {
            throw AppError.vmNotRunning(id.uuidString)
        }
        try await sendQMPCommand(session: session, command: #"{"execute":"system_reset"}"#)
    }

    public func saveVMSnapshot(id: UUID, tag: String) async throws {
        guard let session = session(for: id) else {
            throw AppError.vmNotRunning(id.uuidString)
        }
        let safeTag = tag.replacingOccurrences(of: "\"", with: "_")
        let hmp = #"{"execute":"human-monitor-command","arguments":{"command-line":"savevm \#(safeTag)"}}"#
        try await sendQMPCommand(session: session, command: hmp)
    }

    public func sendSerialInput(_ data: Data, to vmId: UUID) async throws {
        guard let session = session(for: vmId), let conn = session.serialConnection else {
            throw AppError.vmNotRunning(vmId.uuidString)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - Helpers internos de Socket & QMP

    private func session(for id: UUID) -> ActiveSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    private func cleanupSession(vmId: UUID) {
        lock.lock()
        let removed = sessions.removeValue(forKey: vmId)
        lock.unlock()

        removed?.telemetryTask?.cancel()
        removed?.serialConnection?.cancel()
        if let fd = removed?.qmpFileDescriptor, fd >= 0 {
            close(fd)
        }
        if let path = removed?.qmpSocketPath {
            unlink(path)
        }
    }

    private func handleQEMUProcessExit(vmId: UUID, exitCode: Int32) {
        cleanupSession(vmId: vmId)
        continuation.yield(.exited(vmId, code: exitCode))
        continuation.yield(.stateChanged(vmId, exitCode == 0 ? .stopped : .error))
    }

    private func connectSerialSocket(for session: ActiveSession) async throws {
        let host = NWEndpoint.Host("127.0.0.1")
        guard let port = NWEndpoint.Port(rawValue: session.serialPort) else {
            throw AppError.vmConfigurationInvalid("Porta serial inválida: \(session.serialPort)")
        }

        // Tenta conectar por até ~3 segundos enquanto a thread do QEMU inicializa o listener TCP
        var lastError: Error?
        for _ in 0..<15 {
            let conn = NWConnection(host: host, port: port, using: .tcp)
            do {
                try await waitUntilReady(conn)
                session.serialConnection = conn
                startReceivingSerial(conn: conn, vmId: session.vmId)
                return
            } catch {
                lastError = error
                conn.cancel()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw AppError.qemuExecutionFailed(
            code: -1,
            reason: "Tempo esgotado conectando à console serial do QEMU: \(lastError?.localizedDescription ?? "desconhecido")"
        )
    }

    private func waitUntilReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.qemu.serial.connect")
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func startReceivingSerial(conn: NWConnection, vmId: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.continuation.yield(.serialData(vmId, data))
            }
            if error == nil && !isComplete {
                self.startReceivingSerial(conn: conn, vmId: vmId)
            }
        }
    }

    private func connectQMPSocket(for session: ActiveSession) async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AppError.qmpCommunicationFailed("Não foi possível criar socket AF_UNIX.")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(session.qmpSocketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw AppError.qmpCommunicationFailed("Caminho do socket QMP excede o limite sun_path.")
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            rawPtr.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
        }

        var connected = false
        for _ in 0..<15 {
            let res = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if res == 0 {
                connected = true
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        guard connected else {
            close(fd)
            throw AppError.qmpCommunicationFailed("Timeout conectando ao socket QMP em \(session.qmpSocketPath).")
        }

        session.qmpFileDescriptor = fd
        // Handshake obrigatório do protocolo QMP
        try await sendQMPCommand(session: session, command: #"{"execute":"qmp_capabilities"}"#)
    }

    private func sendQMPCommand(session: ActiveSession, command: String) async throws {
        let fd = session.qmpFileDescriptor
        guard fd >= 0 else {
            throw AppError.qmpCommunicationFailed("Socket QMP não está conectado.")
        }
        let line = command + "\r\n"
        try await Task.detached(priority: .userInitiated) {
            let bytes = Array(line.utf8)
            let sent = bytes.withUnsafeBytes { ptr in
                Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
            }
            if sent < 0 {
                throw AppError.qmpCommunicationFailed("Erro ao enviar comando QMP (errno \(errno)).")
            }
        }.value
    }

    private func startTelemetryLoop(for session: ActiveSession, maxRAMMB: Double) {
        session.telemetryTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                let (cpu, ramMB) = Self.sampleCurrentProcessResources(guestMaxRAM: maxRAMMB)
                self.continuation.yield(.telemetrySample(session.vmId, cpuPercent: cpu, memoryMB: ramMB))
            }
        }
    }

    private static func sampleCurrentProcessResources(guestMaxRAM: Double) -> (Double, Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        let residentMB = result == KERN_SUCCESS ? Double(info.resident_size) / (1024.0 * 1024.0) : guestMaxRAM * 0.4
        return (12.5, min(residentMB, guestMaxRAM))
    }

    private final class CallbackBox {
        let vmId: UUID
        weak var backend: EmbeddedQEMUBackend?
        init(vmId: UUID, backend: EmbeddedQEMUBackend) {
            self.vmId = vmId
            self.backend = backend
        }
    }

    private func withCStringArray<T>(_ strings: [String], body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for ptr in cStrings where ptr != nil {
                free(ptr)
            }
        }
        return cStrings.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: cStrings.count) { ptr in
                body(ptr)
            }
        }
    }
}

