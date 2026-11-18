import Foundation

/// Arquitetura emulada suportada pelo QEMU no iOS.
public enum VMArchitecture: String, Codable, CaseIterable, Identifiable, Sendable {
    case aarch64 = "aarch64"
    case x86_64 = "x86_64"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aarch64:
            return "ARM64 (aarch64 — Recomendado)"
        case .x86_64:
            return "x86_64 (PC AMD64)"
        }
    }

    public var qemuBinaryName: String {
        "qemu-system-\(rawValue)"
    }

    public var defaultMachineType: String {
        switch self {
        case .aarch64: return "virt"
        case .x86_64: return "q35"
        }
    }

    public var defaultCPUModel: String {
        switch self {
        case .aarch64: return "cortex-a72"
        case .x86_64: return "qemu64"
        }
    }
}

/// Ordem de boot configurável para o QEMU (`-boot order=...`).
public enum VMBootOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case cdromFirst = "dc"
    case diskFirst = "cd"
    case cdromOnly = "d"
    case diskOnly = "c"
    case network = "n"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cdromFirst: return "ISO (CD-ROM) → Disco"
        case .diskFirst: return "Disco → ISO (CD-ROM)"
        case .cdromOnly: return "Somente ISO (CD-ROM)"
        case .diskOnly: return "Somente Disco (qcow2)"
        case .network: return "Rede (PXE)"
        }
    }
}

/// Modo de aceleração TCG usado pelo QEMU.
public enum VMAccelerationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Tiny Code Interpreter (UTM SE): não exige JIT nem CS_DEBUGGED.
    case tci = "tci"
    /// TCG JIT nativo: exige dispositivo com JIT ativo (AltStore/SideStore/JitStreamer).
    case jit = "jit"
    /// Seleciona JIT automaticamente se CS_DEBUGGED estiver ativo; caso contrário usa TCI.
    case auto = "auto"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automático (JIT se disponível, senão TCI)"
        case .tci: return "TCI sem JIT (Compatível — Estilo UTM SE)"
        case .jit: return "TCG com JIT (Alta Performance — Requer JitStreamer/AltStore)"
        }
    }
}

/// Regra de redirecionamento de porta para rede NAT do QEMU (`hostfwd`).
public struct PortForwardRule: Codable, Identifiable, Hashable, Sendable {
    public enum TransportProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
        case tcp
        case udp

        public var id: String { rawValue }
    }

    public var id: UUID
    public var name: String
    public var transport: TransportProtocol
    public var hostPort: UInt16
    public var guestPort: UInt16

    public init(
        id: UUID = UUID(),
        name: String,
        transport: TransportProtocol = .tcp,
        hostPort: UInt16,
        guestPort: UInt16
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    /// String formatada para o parâmetro `-netdev user,hostfwd=...` do QEMU.
    public var qemuHostFwdArgument: String {
        "hostfwd=\(transport.rawValue)::\(hostPort)-:\(guestPort)"
    }
}

/// Estado atual do ciclo de vida de uma máquina virtual.
public enum VMStatus: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error

    public var displayName: String {
        switch self {
        case .stopped: return "Parada"
        case .starting: return "Iniciando..."
        case .running: return "Rodando"
        case .paused: return "Pausada"
        case .stopping: return "Parando..."
        case .error: return "Erro"
        }
    }

    public var isActive: Bool {
        self == .running || self == .paused || self == .starting
    }
}

/// Modelo completo de configuração e metadados de uma Máquina Virtual Ubuntu Server.
public struct VirtualMachine: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var architecture: VMArchitecture
    public var cpuCores: Int
    public var ramMB: Int
    public var diskSizeGB: Int
    public var diskFileName: String
    public var attachedISOId: UUID?
    public var bootOrder: VMBootOrder
    public var accelerationMode: VMAccelerationMode
    public var natEnabled: Bool
    public var portForwards: [PortForwardRule]
    public var enableVNC: Bool
    public var vncPort: UInt16
    public var enableSPICE: Bool
    public var spicePort: UInt16
    public var serialConsoleEnabled: Bool
    public var extraKernelArgs: String
    public var createdAt: Date
    public var lastStartedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "Ubuntu Server 24.04",
        architecture: VMArchitecture = .aarch64,
        cpuCores: Int = 2,
        ramMB: Int = 1024,
        diskSizeGB: Int = 16,
        diskFileName: String? = nil,
        attachedISOId: UUID? = nil,
        bootOrder: VMBootOrder = .cdromFirst,
        accelerationMode: VMAccelerationMode = .auto,
        natEnabled: Bool = true,
        portForwards: [PortForwardRule] = [
            PortForwardRule(name: "SSH", transport: .tcp, hostPort: 2222, guestPort: 22),
            PortForwardRule(name: "HTTP", transport: .tcp, hostPort: 8080, guestPort: 80)
        ],
        enableVNC: Bool = true,
        vncPort: UInt16 = 5900,
        enableSPICE: Bool = false,
        spicePort: UInt16 = 5930,
        serialConsoleEnabled: Bool = true,
        extraKernelArgs: String = "",
        createdAt: Date = Date(),
        lastStartedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.cpuCores = cpuCores
        self.ramMB = ramMB
        self.diskSizeGB = diskSizeGB
        self.diskFileName = diskFileName ?? "\(id.uuidString).qcow2"
        self.attachedISOId = attachedISOId
        self.bootOrder = bootOrder
        self.accelerationMode = accelerationMode
        self.natEnabled = natEnabled
        self.portForwards = portForwards
        self.enableVNC = enableVNC
        self.vncPort = vncPort
        self.enableSPICE = enableSPICE
        self.spicePort = spicePort
        self.serialConsoleEnabled = serialConsoleEnabled
        self.extraKernelArgs = extraKernelArgs
        self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt
    }

    /// Retorna a primeira regra de redirecionamento cuja porta guest é 22 (SSH), se existir.
    public var sshHostPort: UInt16? {
        portForwards.first(where: { $0.guestPort == 22 && $0.transport == .tcp })?.hostPort
    }

    /// Constrói a lista de argumentos CLI equivalentes do QEMU para execução embarcada e visualização.
    public func buildQEMUArguments(
        diskPath: String,
        isoPath: String?,
        qmpSocketPath: String,
        serialPort: UInt16?,
        useJIT: Bool
    ) -> [String] {
        var args: [String] = [architecture.qemuBinaryName]

        // Máquina e CPU
        if architecture == .aarch64 && useJIT {
            args += ["-machine", "virt,highmem=on"]
            args += ["-cpu", "max"]
        } else {
            args += ["-machine", architecture.defaultMachineType]
            args += ["-cpu", architecture.defaultCPUModel]
        }
        args += ["-smp", "cpus=\(max(1, cpuCores))"]
        args += ["-m", "\(max(256, ramMB))M"]

        // Acelerador TCG: multi-thread + buffer de tradução ampliado quando JIT (StikDebug) está ativo
        if useJIT {
            let jitTBSizeMB = min(max(128, ramMB / 4), 512)
            args += ["-accel", "tcg,thread=multi,tb-size=\(jitTBSizeMB)"]
        } else {
            // Modo TCI (UTM SE): single-thread compatível sem JIT
            let tciTBSizeMB = min(max(64, ramMB / 8), 256)
            args += ["-accel", "tcg,thread=single,tb-size=\(tciTBSizeMB)"]
        }

        // Disco principal QCOW2
        args += ["-drive", "file=\(diskPath),if=virtio,format=qcow2,cache=writethrough"]

        // ISO do Ubuntu Server anexada como CD-ROM
        if let isoPath, !isoPath.isEmpty {
            args += ["-cdrom", isoPath]
        }

        // Ordem de boot
        args += ["-boot", "order=\(bootOrder.rawValue)"]

        // Rede NAT em modo usuário com redirecionamento de portas
        if natEnabled {
            var netdev = "user,id=net0"
            for rule in portForwards {
                netdev += ",\(rule.qemuHostFwdArgument)"
            }
            args += ["-netdev", netdev]
            args += ["-device", "virtio-net-pci,netdev=net0"]
        } else {
            args += ["-nic", "none"]
        }

        // Console serial (-serial / -nographic)
        if serialConsoleEnabled {
            if let serialPort {
                args += ["-serial", "tcp:127.0.0.1:\(serialPort),server=on,wait=off"]
            } else {
                args += ["-serial", "mon:stdio"]
            }
        }

        // Vídeo: headless por padrão ou com VNC/SPICE opcional
        if enableVNC {
            let vncDisplay = max(0, Int(vncPort) - 5900)
            args += ["-vnc", "127.0.0.1:\(vncDisplay)"]
            args += ["-device", "virtio-gpu-pci"]
        } else if enableSPICE {
            args += ["-spice", "port=\(spicePort),addr=127.0.0.1,disable-ticketing=on"]
            args += ["-device", "qxl-vga"]
        } else {
            args += ["-nographic"]
        }

        // Canal QMP para controle (pause, resume, powerdown, query-status)
        args += ["-qmp", "unix:\(qmpSocketPath),server=on,wait=off"]

        if !extraKernelArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let custom = extraKernelArgs.split(separator: " ").map(String.init)
            args.append(contentsOf: custom)
        }

        return args
    }
}

