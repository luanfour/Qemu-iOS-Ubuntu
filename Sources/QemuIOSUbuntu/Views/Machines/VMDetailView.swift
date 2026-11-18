import SwiftUI

/// Tela de detalhes completos de uma Máquina Virtual: controles, telemetria em tempo real,
/// modo servidor, snapshots, linha de comando QEMU e consoles.
public struct VMDetailView: View {
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel
    @EnvironmentObject private var qemuService: QEMUService
    @EnvironmentObject private var backgroundService: BackgroundServerService

    public let vm: VirtualMachine
    public let onOpenSerialTerminal: (VirtualMachine) -> Void
    public let onOpenQuickSSH: (VirtualMachine) -> Void

    @State private var isEditing = false
    @State private var isShowingVNC = false
    @State private var isShowingNewSnapshotAlert = false
    @State private var newSnapshotName = ""
    @State private var isShowingDeleteConfirm = false

    public init(
        vm: VirtualMachine,
        onOpenSerialTerminal: @escaping (VirtualMachine) -> Void,
        onOpenQuickSSH: @escaping (VirtualMachine) -> Void
    ) {
        self.vm = vm
        self.onOpenSerialTerminal = onOpenSerialTerminal
        self.onOpenQuickSSH = onOpenQuickSSH
    }

    private var status: VMStatus {
        qemuService.status(for: vm.id)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerControlsCard
                telemetryCard
                hardwareAndISOCard
                networkAndServerCard
                snapshotsCard
                qemuCommandCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(vm.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Editar") {
                    isEditing = true
                }
                .disabled(status.isActive)

                Menu {
                    Button {
                        vmManagerVM.exportVM(vm)
                    } label: {
                        Label("Exportar Pacote .qemuvm", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        isShowingDeleteConfirm = true
                    } label: {
                        Label("Excluir VM", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            VMEditorView(vm: vm)
        }
        .sheet(isPresented: $isShowingVNC) {
            VNCConsoleView(vm: vm)
        }
        .sheet(
            isPresented: Binding(
                get: { vmManagerVM.exportedBundleURL != nil },
                set: { if !$0 { vmManagerVM.exportedBundleURL = nil } }
            )
        ) {
            if let url = vmManagerVM.exportedBundleURL {
                ShareSheetView(items: [url])
            }
        }
        .alert("Novo Snapshot", isPresented: $isShowingNewSnapshotAlert) {
            TextField("Nome (ex: pos-apt-upgrade)", text: $newSnapshotName)
            Button("Cancelar", role: .cancel) { newSnapshotName = "" }
            Button("Criar") {
                let name = newSnapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
                vmManagerVM.createSnapshot(
                    for: vm,
                    name: name.isEmpty ? "Snapshot \(Date().formatted(date: .numeric, time: .shortened))" : name,
                    notes: "Snapshot QCOW2"
                )
                newSnapshotName = ""
            }
        }
        .confirmationDialog("Excluir '\(vm.name)'?", isPresented: $isShowingDeleteConfirm, titleVisibility: .visible) {
            Button("Excluir VM e Disco QCOW2", role: .destructive) {
                vmManagerVM.deleteVM(vm)
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // MARK: - Seções da Tela

    private var headerControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusBadgeView(status: status)
                Spacer()
                Text(qemuService.capabilities.accelerationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    vmManagerVM.toggleStartPause(vm)
                } label: {
                    Label(
                        status == .running ? "Pausar" : (status == .paused ? "Retomar" : "Iniciar VM"),
                        systemImage: status == .running ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(status == .running ? .orange : .green)
                .disabled(status == .starting || status == .stopping)

                if status.isActive {
                    Button(role: .destructive) {
                        vmManagerVM.stopVM(vm, force: false)
                    } label: {
                        Label("Parar", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vmManagerVM.resetVM(vm)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 10) {
                Button {
                    onOpenSerialTerminal(vm)
                } label: {
                    Label("Terminal Serial", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!status.isActive)

                Button {
                    onOpenQuickSSH(vm)
                } label: {
                    Label("SSH Rápido", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.sshHostPort == nil || status != .running)

                if vm.enableVNC || vm.enableSPICE {
                    Button {
                        isShowingVNC = true
                    } label: {
                        Label("VNC", systemImage: "display")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!status.isActive)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var telemetryCard: some View {
        let tel = qemuService.telemetry
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Telemetria do Servidor", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text("Uptime: \(tel.formattedUptime)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ResourceSparklineView(
                    title: "Uso de CPU",
                    currentValueText: String(format: "%.1f%%", tel.cpuUsagePercent),
                    values: tel.history.map(\.cpuPercent),
                    maxValue: 100,
                    tint: .blue
                )

                ResourceSparklineView(
                    title: "RAM Alocada",
                    currentValueText: "\(Int(tel.memoryUsedMB)) / \(vm.ramMB) MB",
                    values: tel.history.map(\.memoryUsedMB),
                    maxValue: Double(max(256, vm.ramMB)),
                    tint: .purple
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var hardwareAndISOCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hardware e Mídia", systemImage: "cpu")
                .font(.headline)

            infoRow("Arquitetura", vm.architecture.displayName)
            infoRow("vCPUs / RAM", "\(vm.cpuCores) núcleos • \(vm.ramMB) MB")
            infoRow("Disco QCOW2", vmManagerVM.diskPhysicalSizeFormatted(for: vm))
            infoRow("ISO Anexada", vmManagerVM.iso(for: vm)?.displayName ?? "Nenhuma")
            infoRow("Ordem de Boot", vm.bootOrder.displayName)
            infoRow("Modo TCG", vm.accelerationMode.displayName)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var networkAndServerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Rede & Modo Servidor", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if backgroundService.isKeepAliveAudioActive {
                    Label("2º Plano Ativo", systemImage: "speaker.wave.1")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            infoRow("IP Local do Dispositivo", qemuService.telemetry.localIPAddress)
            infoRow("Rede NAT", vm.natEnabled ? "Ativa (User Mode)" : "Desativada")

            if vm.natEnabled && !vm.portForwards.isEmpty {
                Divider()
                ForEach(vm.portForwards) { rule in
                    HStack {
                        Text(rule.name)
                            .font(.subheadline)
                        Spacer()
                        Text("\(qemuService.telemetry.localIPAddress):\(rule.hostPort) → guest:\(rule.guestPort)/\(rule.transport.rawValue)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var snapshotsCard: some View {
        let vmSnapshots = vmManagerVM.snapshots(for: vm.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Snapshots (\(vmSnapshots.count))", systemImage: "camera.on.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingNewSnapshotAlert = true
                } label: {
                    Label("Novo", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

            if vmSnapshots.isEmpty {
                Text("Nenhum snapshot criado ainda para esta VM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vmSnapshots) { snap in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.name)
                                .font(.subheadline.weight(.medium))
                            Text("\(snap.formattedSize) • \(snap.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restaurar") {
                            vmManagerVM.restoreSnapshot(snap, for: vm)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(status.isActive)

                        Button(role: .destructive) {
                            vmManagerVM.deleteSnapshot(snap)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var qemuCommandCard: some View {
        let cmd = vm.buildQEMUArguments(
            diskPath: "Disks/\(vm.diskFileName)",
            isoPath: vmManagerVM.iso(for: vm).map { "ISOs/\($0.fileName)" },
            qmpSocketPath: "/tmp/\(vm.id.uuidString.prefix(8)).qmp",
            serialPort: 4401,
            useJIT: qemuService.capabilities.isJITEnabled && vm.accelerationMode != .tci
        ).joined(separator: " ")

        return VStack(alignment: .leading, spacing: 8) {
            Label("Linha de Comando QEMU Gerada", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.headline)
            Text(cmd)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }
}

