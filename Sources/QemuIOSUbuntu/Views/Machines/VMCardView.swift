import SwiftUI

/// Card resumo de uma Máquina Virtual na lista da aba "Máquinas".
public struct VMCardView: View {
    public let vm: VirtualMachine
    public let status: VMStatus
    public let attachedISO: ISOImage?
    public let isSelected: Bool
    public let onTogglePlayPause: () -> Void
    public let onStop: () -> Void
    public let onOpenSerial: () -> Void
    public let onOpenSSH: () -> Void

    public init(
        vm: VirtualMachine,
        status: VMStatus,
        attachedISO: ISOImage?,
        isSelected: Bool,
        onTogglePlayPause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenSerial: @escaping () -> Void,
        onOpenSSH: @escaping () -> Void
    ) {
        self.vm = vm
        self.status = status
        self.attachedISO = attachedISO
        self.isSelected = isSelected
        self.onTogglePlayPause = onTogglePlayPause
        self.onStop = onStop
        self.onOpenSerial = onOpenSerial
        self.onOpenSSH = onOpenSSH
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(vm.architecture.rawValue) • \(vm.cpuCores) vCPU • \(vm.ramMB) MB RAM • \(vm.diskSizeGB) GB QCOW2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                StatusBadgeView(status: status)
            }

            if let iso = attachedISO {
                Label("ISO: \(iso.displayName)", systemImage: "opticaldisc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Nenhuma ISO anexada", systemImage: "opticaldisc")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if vm.natEnabled && !vm.portForwards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.portForwards) { rule in
                            Text("\(rule.name): \(rule.hostPort)→\(rule.guestPort)")
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: onTogglePlayPause) {
                    Label(playPauseTitle, systemImage: playPauseIcon)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(status == .running ? .orange : .green)
                .disabled(status == .starting || status == .stopping)

                if status.isActive {
                    Button(role: .destructive, action: onStop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Parar VM")
                }

                Spacer()

                if status == .running || status == .paused {
                    Button(action: onOpenSerial) {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Abrir Console Serial")

                    if vm.sshHostPort != nil {
                        Button(action: onOpenSSH) {
                            Image(systemName: "network")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Conectar via SSH")
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var playPauseTitle: String {
        switch status {
        case .running: return "Pausar"
        case .paused: return "Retomar"
        case .starting: return "Iniciando"
        case .stopping: return "Parando"
        case .stopped, .error: return "Iniciar"
        }
    }

    private var playPauseIcon: String {
        switch status {
        case .running: return "pause.fill"
        case .paused, .stopped, .error: return "play.fill"
        case .starting, .stopping: return "hourglass"
        }
    }
}

