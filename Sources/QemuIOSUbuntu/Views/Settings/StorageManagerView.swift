import SwiftUI

/// Tela dedicada de gerenciamento de armazenamento: exibe espaço usado por VMs, ISOs, snapshots
/// e espaço livre no iPhone/iPad, além de ações de limpeza e exportação.
public struct StorageManagerView: View {
    @EnvironmentObject private var vmManagerVM: VMManagerViewModel
    @EnvironmentObject private var settingsVM: SettingsStorageViewModel
    @EnvironmentObject private var qemuService: QEMUService

    @State private var isShowingISOPicker = false

    public init() {}

    public var body: some View {
        List {
            Section("Resumo de Armazenamento") {
                storageRow("Discos & VMs (QCOW2)", bytes: settingsVM.breakdown.vmsBytes, color: .blue)
                storageRow("Imagens ISO", bytes: settingsVM.breakdown.isosBytes, color: .orange)
                storageRow("Snapshots", bytes: settingsVM.breakdown.snapshotsBytes, color: .purple)
                storageRow("Pacotes Exportados", bytes: settingsVM.breakdown.exportsBytes, color: .teal)
                Divider()
                HStack {
                    Text("Total Usado pelo App")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(settingsVM.formatBytes(settingsVM.breakdown.totalAppBytes))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                HStack {
                    Text("Espaço Livre no Dispositivo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(settingsVM.formatBytes(settingsVM.breakdown.deviceAvailableBytes))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.green)
                }
            }

            Section("Discos Virtuais das VMs") {
                ForEach(vmManagerVM.vms) { vm in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.name)
                                .font(.subheadline.weight(.medium))
                            Text(vmManagerVM.diskPhysicalSizeFormatted(for: vm))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Exportar") {
                            vmManagerVM.exportVM(vm)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(qemuService.status(for: vm.id).isActive)
                    }
                }
            }

            Section("Imagens ISO Importadas (\(vmManagerVM.isos.count))") {
                Button {
                    isShowingISOPicker = true
                } label: {
                    Label("Importar ISO do Ubuntu Server", systemImage: "plus.circle")
                }

                ForEach(vmManagerVM.isos) { iso in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(iso.displayName)
                                .font(.subheadline.weight(.medium))
                            Text("\(iso.formattedSize) • SHA256 \(iso.sha256Prefix)...")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            vmManagerVM.deleteISO(iso)
                            settingsVM.refreshStorage()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Todos os Snapshots (\(vmManagerVM.snapshots.count))") {
                if vmManagerVM.snapshots.isEmpty {
                    Text("Nenhum snapshot salvo.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vmManagerVM.snapshots) { snap in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snap.name)
                                    .font(.subheadline.weight(.medium))
                                Text("\(snap.formattedSize) • \(snap.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                vmManagerVM.deleteSnapshot(snap)
                                settingsVM.refreshStorage()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Armazenamento")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settingsVM.refreshStorage()
        }
        .sheet(isPresented: $isShowingISOPicker) {
            DocumentPickerView(contentTypes: [.isoDiskImage, .data]) { urls in
                if let url = urls.first {
                    vmManagerVM.importISO(from: url)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        settingsVM.refreshStorage()
                    }
                }
            }
        }
    }

    private func storageRow(_ label: String, bytes: Int64, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(settingsVM.formatBytes(bytes))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

