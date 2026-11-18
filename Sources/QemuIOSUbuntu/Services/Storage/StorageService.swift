import CryptoKit
import Foundation

/// Serviço responsável pelo gerenciamento de arquivos no sandbox do iOS:
/// VMs, ISOs importadas, discos QCOW2, snapshots, exportação/importação e cálculo de espaço.
public final class StorageService: @unchecked Sendable {
    public let rootDirectory: URL
    public let vmsDirectory: URL
    public let isosDirectory: URL
    public let disksDirectory: URL
    public let snapshotsDirectory: URL
    public let exportsDirectory: URL
    public let runtimeDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let docs = rootDirectory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.rootDirectory = docs
        self.vmsDirectory = docs.appendingPathComponent("VMs", isDirectory: true)
        self.isosDirectory = docs.appendingPathComponent("ISOs", isDirectory: true)
        self.disksDirectory = docs.appendingPathComponent("Disks", isDirectory: true)
        self.snapshotsDirectory = docs.appendingPathComponent("Snapshots", isDirectory: true)
        self.exportsDirectory = docs.appendingPathComponent("Exports", isDirectory: true)
        self.runtimeDirectory = fileManager.temporaryDirectory.appendingPathComponent("QemuRuntime", isDirectory: true)

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        ensureDirectoriesExist()
    }

    private func ensureDirectoriesExist() {
        let dirs = [
            vmsDirectory,
            isosDirectory,
            disksDirectory,
            snapshotsDirectory,
            exportsDirectory,
            runtimeDirectory
        ]
        for dir in dirs {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Caminhos padrão

    public func diskURL(for vm: VirtualMachine) -> URL {
        disksDirectory.appendingPathComponent(vm.diskFileName)
    }

    public func isoURL(for iso: ISOImage) -> URL {
        isosDirectory.appendingPathComponent(iso.fileName)
    }

    public func snapshotURL(for snapshot: VMSnapshot) -> URL {
        snapshotsDirectory.appendingPathComponent(snapshot.fileName)
    }

    public func qmpSocketURL(for vmId: UUID) -> URL {
        runtimeDirectory.appendingPathComponent("\(vmId.uuidString).qmp")
    }

    // MARK: - Persistência JSON

    private var vmsIndexURL: URL { vmsDirectory.appendingPathComponent("vms.json") }
    private var isosIndexURL: URL { isosDirectory.appendingPathComponent("isos.json") }
    private var snapshotsIndexURL: URL { snapshotsDirectory.appendingPathComponent("snapshots.json") }
    private var sshHostsIndexURL: URL { rootDirectory.appendingPathComponent("ssh_hosts.json") }
    private var sshKeysIndexURL: URL { rootDirectory.appendingPathComponent("ssh_keys.json") }

    public func loadVMs() -> [VirtualMachine] {
        loadJSON(from: vmsIndexURL, fallback: [])
    }

    public func saveVMs(_ vms: [VirtualMachine]) throws {
        try saveJSON(vms, to: vmsIndexURL)
    }

    public func loadISOs() -> [ISOImage] {
        loadJSON(from: isosIndexURL, fallback: [])
    }

    public func saveISOs(_ isos: [ISOImage]) throws {
        try saveJSON(isos, to: isosIndexURL)
    }

    public func loadSnapshots() -> [VMSnapshot] {
        loadJSON(from: snapshotsIndexURL, fallback: [])
    }

    public func saveSnapshots(_ snapshots: [VMSnapshot]) throws {
        try saveJSON(snapshots, to: snapshotsIndexURL)
    }

    public func loadSSHHosts() -> [SSHHostProfile] {
        loadJSON(from: sshHostsIndexURL, fallback: [])
    }

    public func saveSSHHosts(_ hosts: [SSHHostProfile]) throws {
        try saveJSON(hosts, to: sshHostsIndexURL)
    }

    public func loadSSHKeys() -> [SSHKeyPair] {
        loadJSON(from: sshKeysIndexURL, fallback: [])
    }

    public func saveSSHKeys(_ keys: [SSHKeyPair]) throws {
        try saveJSON(keys, to: sshKeysIndexURL)
    }

    private func loadJSON<T: Decodable>(from url: URL, fallback: T) -> T {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(T.self, from: data) else {
            return fallback
        }
        return decoded
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Importação de ISO (UIDocumentPicker)

    /// Copia uma ISO selecionada pelo usuário para `Documents/ISOs/` em streaming,
    /// verificando espaço disponível, assinatura ISO 9660 e calculando prefixo SHA-256.
    public func importISO(from sourceURL: URL) async throws -> ISOImage {
        try await Task.detached(priority: .userInitiated) { [self] in
            let needsStopAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if needsStopAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let fileSize = Int64(values.fileSize ?? 0)
            let available = availableDeviceStorageBytes()
            if fileSize > 0 && available > 0 && fileSize > available {
                throw AppError.storageInsufficientSpace(requiredBytes: fileSize, availableBytes: available)
            }

            let originalName = sourceURL.lastPathComponent
            let id = UUID()
            let sanitizedName = "\(id.uuidString.prefix(8))-\(originalName)"
            let destURL = isosDirectory.appendingPathComponent(sanitizedName)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }

            do {
                try fileManager.copyItem(at: sourceURL, to: destURL)
            } catch {
                throw AppError.isoImportFailed(error.localizedDescription)
            }

            let inspection = QCOW2ImageBuilder.inspectISO(at: destURL)
            let actualSize = self.fileSizeBytes(at: destURL)
            let shaPrefix = self.computeSHA256Prefix(for: destURL)

            return ISOImage(
                id: id,
                fileName: sanitizedName,
                displayName: originalName,
                sizeBytes: actualSize,
                sha256Prefix: shaPrefix,
                volumeLabel: inspection.volumeLabel,
                isValidISO9660: inspection.isValidISO9660,
                detectedArchitecture: inspection.detectedArchitecture
            )
        }.value
    }

    public func deleteISO(_ iso: ISOImage) throws {
        let url = isoURL(for: iso)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Discos QCOW2 e Snapshots

    public func ensureDiskExists(for vm: VirtualMachine) throws -> URL {
        let url = diskURL(for: vm)
        if !fileManager.fileExists(atPath: url.path) {
            try QCOW2ImageBuilder.createEmptyQCOW2(at: url, sizeGB: vm.diskSizeGB)
        }
        return url
    }

    public func deleteDisk(for vm: VirtualMachine) throws {
        let url = diskURL(for: vm)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func createDiskSnapshot(for vm: VirtualMachine, name: String, notes: String) async throws -> VMSnapshot {
        try await Task.detached(priority: .userInitiated) { [self] in
            let disk = try ensureDiskExists(for: vm)
            let id = UUID()
            let fileName = "\(vm.id.uuidString)-\(id.uuidString).qcow2.snap"
            let dest = snapshotsDirectory.appendingPathComponent(fileName)

            do {
                try fileManager.copyItem(at: disk, to: dest)
            } catch {
                throw AppError.snapshotOperationFailed(error.localizedDescription)
            }

            let size = self.fileSizeBytes(at: dest)
            return VMSnapshot(
                id: id,
                vmId: vm.id,
                name: name,
                notes: notes,
                fileName: fileName,
                sizeBytes: size
            )
        }.value
    }

    public func restoreDiskSnapshot(_ snapshot: VMSnapshot, for vm: VirtualMachine) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            let snapURL = snapshotURL(for: snapshot)
            guard fileManager.fileExists(atPath: snapURL.path) else {
                throw AppError.fileNotFound(snapURL.lastPathComponent)
            }
            let targetDisk = diskURL(for: vm)
            if fileManager.fileExists(atPath: targetDisk.path) {
                try fileManager.removeItem(at: targetDisk)
            }
            try fileManager.copyItem(at: snapURL, to: targetDisk)
        }.value
    }

    public func deleteSnapshot(_ snapshot: VMSnapshot) throws {
        let url = snapshotURL(for: snapshot)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Exportar e Importar VM (.qemuvm)

    /// Exporta uma VM como pacote `.qemuvm` (diretório com `vm.json` e `disk.qcow2`)
    /// pronto para compartilhamento via Arquivos/AirDrop.
    public func exportVM(_ vm: VirtualMachine) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { [self] in
            let sanitized = vm.name.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let bundleURL = exportsDirectory.appendingPathComponent("\(sanitized)-\(vm.id.uuidString.prefix(6)).qemuvm", isDirectory: true)
            if fileManager.fileExists(atPath: bundleURL.path) {
                try fileManager.removeItem(at: bundleURL)
            }
            try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let configData = try encoder.encode(vm)
            try configData.write(to: bundleURL.appendingPathComponent("vm.json"), options: .atomic)

            let disk = diskURL(for: vm)
            if fileManager.fileExists(atPath: disk.path) {
                try fileManager.copyItem(at: disk, to: bundleURL.appendingPathComponent(vm.diskFileName))
            }
            return bundleURL
        }.value
    }

    /// Importa um pacote `.qemuvm` (pasta contendo `vm.json` e arquivo `.qcow2` opcional).
    public func importVM(from packageURL: URL) async throws -> VirtualMachine {
        try await Task.detached(priority: .userInitiated) { [self] in
            let needsStopAccessing = packageURL.startAccessingSecurityScopedResource()
            defer {
                if needsStopAccessing {
                    packageURL.stopAccessingSecurityScopedResource()
                }
            }

            let configURL = packageURL.appendingPathComponent("vm.json")
            guard fileManager.fileExists(atPath: configURL.path) else {
                throw AppError.exportImportFailed("Pacote .qemuvm inválido: 'vm.json' não encontrado.")
            }

            let data = try Data(contentsOf: configURL)
            var imported = try decoder.decode(VirtualMachine.self, from: data)
            let newId = UUID()
            let oldDiskName = imported.diskFileName
            imported.id = newId
            imported.name = "\(imported.name) (Importada)"
            imported.diskFileName = "\(newId.uuidString).qcow2"
            imported.lastStartedAt = nil

            let oldDiskURL = packageURL.appendingPathComponent(oldDiskName)
            let newDiskURL = diskURL(for: imported)
            if fileManager.fileExists(atPath: oldDiskURL.path) {
                try fileManager.copyItem(at: oldDiskURL, to: newDiskURL)
            } else {
                try QCOW2ImageBuilder.createEmptyQCOW2(at: newDiskURL, sizeGB: imported.diskSizeGB)
            }

            return imported
        }.value
    }

    // MARK: - Métricas de Espaço

    public func computeStorageBreakdown() -> StorageBreakdown {
        StorageBreakdown(
            vmsBytes: directorySizeBytes(at: disksDirectory) + directorySizeBytes(at: vmsDirectory),
            isosBytes: directorySizeBytes(at: isosDirectory),
            snapshotsBytes: directorySizeBytes(at: snapshotsDirectory),
            exportsBytes: directorySizeBytes(at: exportsDirectory),
            deviceAvailableBytes: availableDeviceStorageBytes()
        )
    }

    public func fileSizeBytes(at url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    public func availableDeviceStorageBytes() -> Int64 {
        let values = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let regular = values?.volumeAvailableCapacity {
            return Int64(regular)
        }
        return 0
    }

    private func directorySizeBytes(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func computeSHA256Prefix(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "n/d" }
        defer { try? handle.close() }
        var hasher = SHA256()
        // Lê até 16 MiB iniciais para hash rápido de identificação sem travar a importação de ISOs grandes
        if let chunk = try? handle.read(upToCount: 16 * 1024 * 1024) {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

