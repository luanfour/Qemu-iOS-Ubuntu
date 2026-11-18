import SwiftUI
import UniformTypeIdentifiers

/// Aba "Máquinas" adaptativa: usa `NavigationSplitView` no iPad (horizontal/regular) e `NavigationStack` no iPhone.
public struct MachinesListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel
    @EnvironmentObject private var qemuService: QEMUService

    public let onOpenSerialTerminal: (VirtualMachine) -> Void
    public let onOpenQuickSSH: (VirtualMachine) -> Void

    @State private var isShowingNewVM = false
    @State private var isShowingISOPicker = false
    @State private var isShowingImportVMPicker = false

    public init(
        onOpenSerialTerminal: @escaping (VirtualMachine) -> Void,
        onOpenQuickSSH: @escaping (VirtualMachine) -> Void
    ) {
        self.onOpenSerialTerminal = onOpenSerialTerminal
        self.onOpenQuickSSH = onOpenQuickSSH
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    vmListContent
                        .navigationTitle("Máquinas")
                        .toolbar { toolbarContent }
                } detail: {
                    if let vm = vmManagerVM.selectedVM {
                        VMDetailView(
                            vm: vm,
                            onOpenSerialTerminal: onOpenSerialTerminal,
                            onOpenQuickSSH: onOpenQuickSSH
                        )
                    } else {
                        emptySelectionView
                    }
                }
            } else {
                NavigationStack {
                    vmListContent
                        .navigationTitle("Máquinas")
                        .toolbar { toolbarContent }
                        .navigationDestination(for: UUID.self) { vmId in
                            if let vm = vmManagerVM.vms.first(where: { $0.id == vmId }) {
                                VMDetailView(
                                    vm: vm,
                                    onOpenSerialTerminal: onOpenSerialTerminal,
                                    onOpenQuickSSH: onOpenQuickSSH
                                )
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $isShowingNewVM) {
            VMEditorView()
        }
        .sheet(isPresented: $isShowingISOPicker) {
            DocumentPickerView(contentTypes: [.isoDiskImage, .data]) { urls in
                if let url = urls.first {
                    vmManagerVM.importISO(from: url)
                }
            }
        }
        .sheet(isPresented: $isShowingImportVMPicker) {
            DocumentPickerView(contentTypes: [.qemuVMFolder]) { urls in
                if let url = urls.first {
                    vmManagerVM.importVM(from: url)
                }
            }
        }
    }

    private var vmListContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                backendStatusBanner

                if vmManagerVM.isImportingISO {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Copiando imagem ISO para o sandbox...")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                ForEach(vmManagerVM.vms) { vm in
                    if horizontalSizeClass == .regular {
                        Button {
                            vmManagerVM.selectedVMId = vm.id
                        } label: {
                            makeCard(for: vm)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: vm.id) {
                            makeCard(for: vm)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !vmManagerVM.isos.isEmpty {
                    isosQuickListCard
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func makeCard(for vm: VirtualMachine) -> some View {
        VMCardView(
            vm: vm,
            status: qemuService.status(for: vm.id),
            attachedISO: vmManagerVM.iso(for: vm),
            isSelected: horizontalSizeClass == .regular && vmManagerVM.selectedVMId == vm.id,
            onTogglePlayPause: { vmManagerVM.toggleStartPause(vm) },
            onStop: { vmManagerVM.stopVM(vm, force: false) },
            onOpenSerial: { onOpenSerialTerminal(vm) },
            onOpenSSH: { onOpenQuickSSH(vm) }
        )
    }

    private var backendStatusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: qemuService.isUsingRealQEMU ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                    .foregroundStyle(qemuService.isUsingRealQEMU ? .green : .orange)
                Text(qemuService.activeBackendName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(qemuService.capabilities.isJITEnabled ? "JIT OK" : "TCI")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((qemuService.capabilities.isJITEnabled ? Color.green : Color.blue).opacity(0.15))
                    .foregroundStyle(qemuService.capabilities.isJITEnabled ? .green : .blue)
                    .clipShape(Capsule())
            }

            Text("IP Local: \(qemuService.telemetry.localIPAddress) • Ativas: \(qemuService.runningVMIds.count) • Uptime: \(qemuService.telemetry.formattedUptime)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !qemuService.capabilities.isJITEnabled {
                HStack(spacing: 8) {
                    Text(qemuService.capabilities.hasOnDeviceJITEnabler
                         ? "StikDebug detectado — habilite o JIT para máximo desempenho."
                         : "Rodando sem JIT (modo TCI). Use StikDebug para acelerar o QEMU.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        qemuService.requestJITWithStikDebug()
                    } label: {
                        Label("Ativar JIT", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isosQuickListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("ISOs Importadas (\(vmManagerVM.isos.count))", systemImage: "opticaldisc.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Importar ISO") {
                    isShowingISOPicker = true
                }
                .font(.caption)
            }

            ForEach(vmManagerVM.isos) { iso in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(iso.displayName)
                            .font(.caption.weight(.medium))
                        Text("\(iso.formattedSize) • \(iso.volumeLabel) • \(iso.detectedArchitecture?.rawValue ?? "arq. mista")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        vmManagerVM.deleteISO(iso)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var emptySelectionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("Selecione uma Máquina Virtual")
                .font(.headline)
            Text("Escolha uma VM à esquerda ou crie uma nova para executar o Ubuntu Server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    isShowingISOPicker = true
                } label: {
                    Label("Importar ISO do Ubuntu Server", systemImage: "opticaldisc")
                }

                Button {
                    isShowingImportVMPicker = true
                } label: {
                    Label("Importar Pacote .qemuvm", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }

            Button {
                isShowingNewVM = true
            } label: {
                Image(systemName: "plus")
            }
        }
    }
}

