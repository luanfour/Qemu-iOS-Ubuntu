import Foundation

/// Contexto completo de inicialização passado para o backend QEMU.
public struct QEMUStartContext: Sendable {
    public let vm: VirtualMachine
    public let diskPath: String
    public let isoPath: String?
    public let qmpSocketPath: String
    public let serialTCPPort: UInt16
    public let useJIT: Bool
    public let arguments: [String]

    public init(
        vm: VirtualMachine,
        diskPath: String,
        isoPath: String?,
        qmpSocketPath: String,
        serialTCPPort: UInt16,
        useJIT: Bool,
        arguments: [String]
    ) {
        self.vm = vm
        self.diskPath = diskPath
        self.isoPath = isoPath
        self.qmpSocketPath = qmpSocketPath
        self.serialTCPPort = serialTCPPort
        self.useJIT = useJIT
        self.arguments = arguments
    }
}

/// Eventos assíncronos emitidos por um backend QEMU em execução.
public enum QEMUBackendEvent: Sendable {
    case stateChanged(UUID, VMStatus)
    case serialData(UUID, Data)
    case telemetrySample(UUID, cpuPercent: Double, memoryMB: Double)
    case logMessage(UUID, String)
    case exited(UUID, code: Int32)
}

/// Protocolo de abstração do motor QEMU (`QEMUBackend`).
/// Permite alternar perfeitamente entre o framework QEMU nativo pré-compilado (`EmbeddedQEMUBackend`)
/// e o backend de diagnóstico/simulação (`SimulatedQEMUBackend`) quando o XCFramework ainda não foi linkado.
public protocol QEMUBackend: AnyObject, Sendable {
    /// Nome legível do backend para exibição na interface.
    var backendDisplayName: String { get }

    /// Indica se este backend executa virtualização real via `libqemu`.
    var isHardwareOrTCIVirtualizationReal: Bool { get }

    /// Stream de eventos emitidos pelo backend.
    var events: AsyncStream<QEMUBackendEvent> { get }

    /// Inicia uma VM usando o contexto especificado.
    func startVM(context: QEMUStartContext) async throws

    /// Pausa a execução da CPU virtual (QMP `stop`).
    func pauseVM(id: UUID) async throws

    /// Retoma a execução da VM pausada (QMP `cont`).
    func resumeVM(id: UUID) async throws

    /// Solicita desligamento limpo (ACPI `system_powerdown`) ou forçado (QMP `quit`).
    func stopVM(id: UUID, force: Bool) async throws

    /// Reinicia a VM (QMP `system_reset`).
    func resetVM(id: UUID) async throws

    /// Cria um snapshot interno via QMP `savevm` (quando suportado pelo backend).
    func saveVMSnapshot(id: UUID, tag: String) async throws

    /// Envia bytes digitados no terminal para a console serial da VM.
    func sendSerialInput(_ data: Data, to vmId: UUID) async throws
}

