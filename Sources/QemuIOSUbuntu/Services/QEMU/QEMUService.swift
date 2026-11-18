import Combine
import Foundation

/// Serviço central de gerenciamento do ciclo de vida das máquinas virtuais QEMU.
/// Seleciona automaticamente entre `EmbeddedQEMUBackend` (quando `libqemu.xcframework`
/// está presente) e `SimulatedQEMUBackend` (modo diagnóstico TCI sem binário nativo).
@MainActor
public final class QEMUService: ObservableObject {
    @Published public private(set) var vmStatuses: [UUID: VMStatus] = [:]
    @Published public private(set) var telemetry: SystemTelemetry = SystemTelemetry()
    @Published public private(set) var capabilities: RuntimeCapabilities
    @Published public private(set) var activeBackendName: String
    @Published public private(set) var isUsingRealQEMU: Bool
    @Published public private(set) var consoleLogs: [UUID: [String]] = [:]
    @Published public var autoRequestStikDebugOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoRequestStikDebugOnLaunch, forKey: "autoRequestStikDebugOnLaunch")
        }
    }

    /// Callback assíncrono disparado sempre que bytes chegam da console serial de uma VM.
    public var onSerialDataReceived: ((UUID, Data) -> Void)?

    private let storageService: StorageService
    private let backgroundService: BackgroundServerService
    private let backend: QEMUBackend
    private var eventListenerTask: Task<Void, Never>?
    private var uptimeTimerTask: Task<Void, Never>?
    private var runningStartDates: [UUID: Date] = [:]
    private var activeVMsById: [UUID: VirtualMachine] = [:]
    private var serialPortCursor: UInt16 = 4400

    public init(
        storageService: StorageService,
        backgroundService: BackgroundServerService,
        preferredBackend: QEMUBackend? = nil
    ) {
        self.storageService = storageService
        self.backgroundService = backgroundService

        let caps = JITDetector.currentCapabilities()
        self.capabilities = caps
        self.autoRequestStikDebugOnLaunch = UserDefaults.standard.object(forKey: "autoRequestStikDebugOnLaunch") as? Bool ?? false

        if let preferredBackend {
            self.backend = preferredBackend
        } else if caps.isAnyEmbeddedQEMULinked {
            self.backend = EmbeddedQEMUBackend()
        } else {
            self.backend = SimulatedQEMUBackend()
        }

        self.activeBackendName = self.backend.backendDisplayName
        self.isUsingRealQEMU = self.backend.isHardwareOrTCIVirtualizationReal
        self.telemetry.localIPAddress = caps.localIPAddress

        listenToBackendEvents()
        startUptimeTimer()
    }

    deinit {
        eventListenerTask?.cancel()
        uptimeTimerTask?.cancel()
    }

    public func refreshCapabilities() {
        capabilities = JITDetector.currentCapabilities()
        telemetry.localIPAddress = capabilities.localIPAddress
    }

    public func requestJITWithStikDebug() {
        JITDetector.requestJITViaStikDebug()
    }

    public func status(for vmId: UUID) -> VMStatus {
        vmStatuses[vmId] ?? .stopped
    }

    public var runningVMIds: [UUID] {
        vmStatuses.filter { $0.value == .running || $0.value == .paused }.map(\.key)
    }

    public func startVM(_ vm: VirtualMachine, attachedISO: ISOImage?) async throws {
        let current = status(for: vm.id)
        guard current == .stopped || current == .error else {
            throw AppError.vmAlreadyRunning(vm.name)
        }

        if vm.bootOrder == .cdromOnly && attachedISO == nil {
            throw AppError.vmConfigurationInvalid("A ordem de boot exige uma ISO anexada, mas nenhuma ISO foi selecionada.")
        }

        let diskURL = try storageService.ensureDiskExists(for: vm)
        let isoPath = attachedISO.map { storageService.isoURL(for: $0).path }
        if let isoPath, !FileManager.default.fileExists(atPath: isoPath) {
            throw AppError.fileNotFound(isoPath)
        }

        let useJIT: Bool
        switch vm.accelerationMode {
        case .tci:
            useJIT = false
        case .jit:
            guard capabilities.isJITEnabled else {
                throw AppError.vmConfigurationInvalid(
                    "Modo JIT forçado selecionado, mas CS_DEBUGGED está desativado. Ative o JIT via AltStore/SideStore/JitStreamer ou mude para TCI/Automático."
                )
            }
            useJIT = true
        case .auto:
            useJIT = capabilities.isJITEnabled
        }

        serialPortCursor = serialPortCursor >= 4499 ? 4400 : serialPortCursor + 1
        let serialPort = serialPortCursor
        let qmpSocket = storageService.qmpSocketURL(for: vm.id).path

        let args = vm.buildQEMUArguments(
            diskPath: diskURL.path,
            isoPath: isoPath,
            qmpSocketPath: qmpSocket,
            serialPort: serialPort,
            useJIT: useJIT
        )

        let context = QEMUStartContext(
            vm: vm,
            diskPath: diskURL.path,
            isoPath: isoPath,
            qmpSocketPath: qmpSocket,
            serialTCPPort: serialPort,
            useJIT: useJIT,
            arguments: args
        )

        activeVMsById[vm.id] = vm
        runningStartDates[vm.id] = Date()
        updateExposedPortsAndMemory()

        try await backend.startVM(context: context)
        backgroundService.onVMStarted(vm: vm)
    }

    public func pauseVM(_ vm: VirtualMachine) async throws {
        try await backend.pauseVM(id: vm.id)
    }

    public func resumeVM(_ vm: VirtualMachine) async throws {
        try await backend.resumeVM(id: vm.id)
    }

    public func stopVM(_ vm: VirtualMachine, force: Bool = false) async throws {
        try await backend.stopVM(id: vm.id, force: force)
    }

    public func resetVM(_ vm: VirtualMachine) async throws {
        try await backend.resetVM(id: vm.id)
    }

    public func saveLiveSnapshot(vm: VirtualMachine, tag: String) async throws {
        try await backend.saveVMSnapshot(id: vm.id, tag: tag)
    }

    public func sendSerialInput(_ data: Data, to vmId: UUID) async throws {
        try await backend.sendSerialInput(data, to: vmId)
    }

    // MARK: - Processamento de eventos do backend

    private func listenToBackendEvents() {
        let stream = backend.events
        eventListenerTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: QEMUBackendEvent) {
        switch event {
        case .stateChanged(let vmId, let newStatus):
            vmStatuses[vmId] = newStatus
            if newStatus == .stopped || newStatus == .error {
                let name = activeVMsById[vmId]?.name ?? "VM"
                runningStartDates.removeValue(forKey: vmId)
                activeVMsById.removeValue(forKey: vmId)
                updateExposedPortsAndMemory()
                backgroundService.onVMStopped(vmId: vmId, vmName: name, hasRemainingActiveVMs: !runningVMIds.isEmpty)
            } else {
                updateExposedPortsAndMemory()
            }

        case .serialData(let vmId, let data):
            onSerialDataReceived?(vmId, data)

        case .telemetrySample(_, let cpuPercent, let memoryMB):
            telemetry.cpuUsagePercent = cpuPercent
            telemetry.memoryUsedMB = memoryMB
            var history = telemetry.history
            history.append(TelemetrySample(timestamp: Date(), cpuPercent: cpuPercent, memoryUsedMB: memoryMB))
            if history.count > 40 {
                history.removeFirst(history.count - 40)
            }
            telemetry.history = history

        case .logMessage(let vmId, let line):
            var logs = consoleLogs[vmId] ?? []
            logs.append(line)
            if logs.count > 200 {
                logs.removeFirst(logs.count - 200)
            }
            consoleLogs[vmId] = logs

        case .exited(let vmId, let code):
            var logs = consoleLogs[vmId] ?? []
            logs.append("[QEMU] Processo encerrado (código \(code)).")
            consoleLogs[vmId] = logs
        }
    }

    private func updateExposedPortsAndMemory() {
        let activeVMs = activeVMsById.values
        telemetry.memoryAllocatedMB = Double(activeVMs.reduce(0) { $0 + $1.ramMB })
        telemetry.exposedPorts = activeVMs.flatMap { $0.natEnabled ? $0.portForwards : [] }
        if activeVMs.isEmpty {
            telemetry.cpuUsagePercent = 0
            telemetry.memoryUsedMB = 0
            telemetry.uptimeSeconds = 0
        }
    }

    private func startUptimeTimer() {
        uptimeTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { break }
                if let earliest = self.runningStartDates.values.min() {
                    self.telemetry.uptimeSeconds = Date().timeIntervalSince(earliest)
                } else {
                    self.telemetry.uptimeSeconds = 0
                }
            }
        }
    }
}

