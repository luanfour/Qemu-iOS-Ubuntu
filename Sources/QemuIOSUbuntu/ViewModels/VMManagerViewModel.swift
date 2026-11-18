import Foundation
import SwiftUI

/// ViewModel responsável pela aba "Máquinas": CRUD de VMs, importação de ISOs,
/// controle de ciclo de vida (Play/Pause/Stop/Reset) e snapshots por VM.
@MainActor
public final class VMManagerViewModel: ObservableObject {
    @Published public private(set) var vms: [VirtualMachine] = []
    @Published public private(set) var isos: [ISOImage] = []
    @Published public private(set) var snapshots: [VMSnapshot] = []
    @Published public var selectedVMId: UUID?
    @Published public var isImportingISO: Bool = false
    @Published public var isBusy: Bool = false
    @Published public var activeErrorMessage: String?
    @Published public var exportedBundleURL: URL?

    private let storageService: StorageService
    private let qemuService: QEMUService

    public init(storageService: StorageService, qemuService: QEMUService) {
        self.storageService = storageService
        self.qemuService = qemuService
        reloadAll()
    }

    public func reloadAll() {
        vms = storageService.loadVMs()
        isos = storageService.loadISOs()
        snapshots = storageService.loadSnapshots()

        if vms.isEmpty {
            let sample = VirtualMachine(
                name: "Ubuntu Server 24.04 ARM64",
                architecture: .aarch64,
                cpuCores: 2,
                ramMB: 1024,
                diskSizeGB: 16
            )
            vms = [sample]
            try? storageService.saveVMs(vms)
        }

        if selectedVMId == nil {
            selectedVMId = vms.first?.id
        }
    }

    public var selectedVM: VirtualMachine? {
        guard let id = selectedVMId else { return vms.first }
        return vms.first(where: { $0.id == id })
    }

    public func iso(for vm: VirtualMachine) -> ISOImage? {
        guard let isoId = vm.attachedISOId else { return nil }
        return isos.first(where: { $0.id == isoId })
    }

    public func snapshots(for vmId: UUID) -> [VMSnapshot] {
        snapshots.filter { $0.vmId == vmId }.sorted { $0.createdAt > $1.createdAt }
    }

    public func diskPhysicalSizeFormatted(for vm: VirtualMachine) -> String {
        let bytes = storageService.fileSizeBytes(at: storageService.diskURL(for: vm))
        if bytes == 0 {
            return "Não alocado (\(vm.diskSizeGB) GB virtuais)"
        }
        let phys = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(phys) / \(vm.diskSizeGB) GB"
    }

    // MARK: - CRUD de VMs

    public func saveVM(_ vm: VirtualMachine) {
        do {
            _ = try storageService.ensureDiskExists(for: vm)
            if let index = vms.firstIndex(where: { $0.id == vm.id }) {
                vms[index] = vm
            } else {
                vms.append(vm)
                selectedVMId = vm.id
            }
            try storageService.saveVMs(vms)
        } catch {
            activeErrorMessage = error.localizedDescription
        }
    }

    public func deleteVM(_ vm: VirtualMachine) {
        Task {
            if qemuService.status(for: vm.id).isActive {
                try? await qemuService.stopVM(vm, force: true)
            }
            do {
                try storageService.deleteDisk(for: vm)
                for snap in snapshots(for: vm.id) {
                    try? storageService.deleteSnapshot(snap)
                }
                snapshots.removeAll { $0.vmId == vm.id }
                vms.removeAll { $0.id == vm.id }
                try storageService.saveSnapshots(snapshots)
                try storageService.saveVMs(vms)
                if selectedVMId == vm.id {
                    selectedVMId = vms.first?.id
                }
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Controle de Execução

    public func toggleStartPause(_ vm: VirtualMachine) {
        let status = qemuService.status(for: vm.id)
        Task {
            do {
                switch status {
                case .stopped, .error:
                    try await startVM(vm)
                case .running:
                    try await qemuService.pauseVM(vm)
                case .paused:
                    try await qemuService.resumeVM(vm)
                case .starting, .stopping:
                    break
                }
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func startVM(_ vm: VirtualMachine) async throws {
        if let index = vms.firstIndex(where: { $0.id == vm.id }) {
            vms[index].lastStartedAt = Date()
            try? storageService.saveVMs(vms)
        }
        let attached = iso(for: vm)
        try await qemuService.startVM(vm, attachedISO: attached)
    }

    public func stopVM(_ vm: VirtualMachine, force: Bool = false) {
        Task {
            do {
                try await qemuService.stopVM(vm, force: force)
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func resetVM(_ vm: VirtualMachine) {
        Task {
            do {
                try await qemuService.resetVM(vm)
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Importação de ISO

    public func importISO(from url: URL) {
        isImportingISO = true
        Task {
            defer { isImportingISO = false }
            do {
                let imported = try await storageService.importISO(from: url)
                isos.append(imported)
                try storageService.saveISOs(isos)
                if !imported.isValidISO9660 {
                    activeErrorMessage = "Aviso: '\(imported.displayName)' foi importado, mas a assinatura ISO 9660 (CD001) não foi encontrada."
                }
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func deleteISO(_ iso: ISOImage) {
        do {
            try storageService.deleteISO(iso)
            isos.removeAll { $0.id == iso.id }
            for idx in vms.indices where vms[idx].attachedISOId == iso.id {
                vms[idx].attachedISOId = nil
            }
            try storageService.saveISOs(isos)
            try storageService.saveVMs(vms)
        } catch {
            activeErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Snapshots & Exportação

    public func createSnapshot(for vm: VirtualMachine, name: String, notes: String) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if qemuService.status(for: vm.id) == .running {
                    try? await qemuService.saveLiveSnapshot(vm: vm, tag: name)
                }
                let snap = try await storageService.createDiskSnapshot(for: vm, name: name, notes: notes)
                snapshots.append(snap)
                try storageService.saveSnapshots(snapshots)
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func restoreSnapshot(_ snapshot: VMSnapshot, for vm: VirtualMachine) {
        guard !qemuService.status(for: vm.id).isActive else {
            activeErrorMessage = "Pare a VM '\(vm.name)' antes de restaurar um snapshot."
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await storageService.restoreDiskSnapshot(snapshot, for: vm)
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func deleteSnapshot(_ snapshot: VMSnapshot) {
        do {
            try storageService.deleteSnapshot(snapshot)
            snapshots.removeAll { $0.id == snapshot.id }
            try storageService.saveSnapshots(snapshots)
        } catch {
            activeErrorMessage = error.localizedDescription
        }
    }

    public func exportVM(_ vm: VirtualMachine) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let url = try await storageService.exportVM(vm)
                exportedBundleURL = url
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }

    public func importVM(from url: URL) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let imported = try await storageService.importVM(from: url)
                vms.append(imported)
                try storageService.saveVMs(vms)
                selectedVMId = imported.id
            } catch {
                activeErrorMessage = error.localizedDescription
            }
        }
    }
}

