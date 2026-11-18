import Foundation

/// Ponto histórico de telemetria para gráficos de CPU e memória em tempo real.
public struct TelemetrySample: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let cpuPercent: Double
    public let memoryUsedMB: Double
}

/// Métricas agregadas do servidor iOS e das VMs em execução.
public struct SystemTelemetry: Sendable {
    public var cpuUsagePercent: Double
    public var memoryUsedMB: Double
    public var memoryAllocatedMB: Double
    public var uptimeSeconds: TimeInterval
    public var localIPAddress: String
    public var exposedPorts: [PortForwardRule]
    public var history: [TelemetrySample]

    public init(
        cpuUsagePercent: Double = 0,
        memoryUsedMB: Double = 0,
        memoryAllocatedMB: Double = 0,
        uptimeSeconds: TimeInterval = 0,
        localIPAddress: String = "127.0.0.1",
        exposedPorts: [PortForwardRule] = [],
        history: [TelemetrySample] = []
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsedMB = memoryUsedMB
        self.memoryAllocatedMB = memoryAllocatedMB
        self.uptimeSeconds = uptimeSeconds
        self.localIPAddress = localIPAddress
        self.exposedPorts = exposedPorts
        self.history = history
    }

    /// Formata o uptime no padrão `HH:mm:ss`.
    public var formattedUptime: String {
        let total = max(0, Int(uptimeSeconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

/// Resumo do uso de espaço em disco no sandbox do aplicativo.
public struct StorageBreakdown: Sendable {
    public var vmsBytes: Int64
    public var isosBytes: Int64
    public var snapshotsBytes: Int64
    public var exportsBytes: Int64
    public var deviceAvailableBytes: Int64

    public var totalAppBytes: Int64 {
        vmsBytes + isosBytes + snapshotsBytes + exportsBytes
    }

    public static let empty = StorageBreakdown(
        vmsBytes: 0,
        isosBytes: 0,
        snapshotsBytes: 0,
        exportsBytes: 0,
        deviceAvailableBytes: 0
    )
}

