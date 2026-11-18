import Foundation

/// Resultado da inspeção de um arquivo ISO 9660.
public struct ISOInspectionResult: Sendable {
    public let isValidISO9660: Bool
    public let volumeLabel: String
    public let detectedArchitecture: VMArchitecture?
}

/// Utilitário em Swift puro para gerar cabeçalhos QCOW2 v3 válidos (esparsos)
/// e inspecionar metadados de imagens ISO 9660 sem depender de binários externos (`qemu-img`).
public enum QCOW2ImageBuilder {
    private static let qcow2Magic: UInt32 = 0x514649FB // "QFI\xfb"
    private static let qcow2Version3: UInt32 = 3
    private static let clusterBits: UInt32 = 16 // 64 KiB por cluster
    private static let clusterSize: UInt64 = 1 << 16 // 65536 bytes

    /// Cria um arquivo QCOW2 v3 esparso válido no caminho especificado.
    /// Um disco virtual de 16 GB ocupa inicialmente apenas ~192 KiB no sandbox do iPhone.
    public static func createEmptyQCOW2(at url: URL, sizeGB: Int) throws {
        let clampedGB = max(1, min(sizeGB, 512))
        let virtualSizeBytes = UInt64(clampedGB) * 1024 * 1024 * 1024

        // Cálculo do tamanho da tabela L1:
        // Cada cluster L2 (64 KiB) contém 8192 entradas de 8 bytes (512 MiB endereçáveis por L2)
        let l2EntriesPerCluster = clusterSize / 8
        let totalClusters = (virtualSizeBytes + clusterSize - 1) / clusterSize
        let l1Entries = max(1, (totalClusters + l2EntriesPerCluster - 1) / l2EntriesPerCluster)
        let l1Bytes = l1Entries * 8
        let l1Clusters = max(1, (l1Bytes + clusterSize - 1) / clusterSize)

        // Layout inicial do arquivo QCOW2 v3:
        // Cluster 0 (offset 0): Cabeçalho (104 bytes + padding)
        // Cluster 1 (offset 65536): Tabela de refcount (1 entrada apontando para Cluster 2)
        // Cluster 2 (offset 131072): Bloco de refcount cobrindo os primeiros clusters
        // Cluster 3 (offset 196608): Tabela L1 zerada
        let refcountTableOffset: UInt64 = clusterSize * 1
        let refcountBlockOffset: UInt64 = clusterSize * 2
        let l1TableOffset: UInt64 = clusterSize * 3
        let totalInitialClusters: UInt64 = 3 + l1Clusters
        let totalFileSize = totalInitialClusters * clusterSize

        var imageData = Data(count: Int(totalFileSize))

        imageData.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }

            func writeUInt32(_ value: UInt32, at offset: Int) {
                var big = value.bigEndian
                memcpy(base.advanced(by: offset), &big, 4)
            }

            func writeUInt64(_ value: UInt64, at offset: Int) {
                var big = value.bigEndian
                memcpy(base.advanced(by: offset), &big, 8)
            }

            func writeUInt16(_ value: UInt16, at offset: Int) {
                var big = value.bigEndian
                memcpy(base.advanced(by: offset), &big, 2)
            }

            // Cabeçalho QCOW2 v3 (especificação oficial QEMU docs/interop/qcow2.txt)
            writeUInt32(qcow2Magic, at: 0)           // magic
            writeUInt32(qcow2Version3, at: 4)        // version
            writeUInt64(0, at: 8)                    // backing_file_offset
            writeUInt32(0, at: 16)                   // backing_file_size
            writeUInt32(clusterBits, at: 20)         // cluster_bits
            writeUInt64(virtualSizeBytes, at: 24)    // size
            writeUInt32(0, at: 32)                   // crypt_method (nenhuma)
            writeUInt32(UInt32(l1Entries), at: 36)   // l1_size
            writeUInt64(l1TableOffset, at: 40)       // l1_table_offset
            writeUInt64(refcountTableOffset, at: 48) // refcount_table_offset
            writeUInt32(1, at: 56)                   // refcount_table_clusters
            writeUInt32(0, at: 60)                   // nb_snapshots
            writeUInt64(0, at: 64)                   // snapshots_offset
            // Campos exclusivos da versão 3:
            writeUInt64(0, at: 72)                   // incompatible_features
            writeUInt64(0, at: 80)                   // compatible_features
            writeUInt64(0, at: 88)                   // autoclear_features
            writeUInt32(4, at: 96)                   // refcount_order (4 => 16 bits por refcount)
            writeUInt32(104, at: 100)                // header_length

            // Refcount table[0] -> aponta para refcountBlockOffset
            writeUInt64(refcountBlockOffset, at: Int(refcountTableOffset))

            // Marca refcount = 1 para todos os clusters iniciais (header, refcount table, refcount block, L1)
            for clusterIndex in 0..<Int(totalInitialClusters) {
                writeUInt16(1, at: Int(refcountBlockOffset) + (clusterIndex * 2))
            }
        }

        do {
            try imageData.write(to: url, options: .atomic)
        } catch {
            throw AppError.diskCreationFailed(error.localizedDescription)
        }
    }

    /// Verifica se um arquivo é um QCOW2 válido lendo os primeiros 8 bytes.
    public static func isValidQCOW2(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count == 8 else { return false }
        let magic = data.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        return magic == qcow2Magic
    }

    /// Lê o Primary Volume Descriptor (offset 0x8000) de uma imagem ISO 9660.
    public static func inspectISO(at url: URL) -> ISOInspectionResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ISOInspectionResult(isValidISO9660: false, volumeLabel: url.deletingPathExtension().lastPathComponent, detectedArchitecture: nil)
        }
        defer { try? handle.close() }

        let pvdOffset: UInt64 = 0x8000
        do {
            try handle.seek(toOffset: pvdOffset)
            guard let sector = try handle.read(upToCount: 128), sector.count >= 72 else {
                return ISOInspectionResult(isValidISO9660: false, volumeLabel: url.deletingPathExtension().lastPathComponent, detectedArchitecture: nil)
            }

            // Byte 0 = 0x01 (Primary Volume Descriptor), Bytes 1..5 = "CD001"
            let isPVD = sector[0] == 0x01
            let signature = String(bytes: sector[1...5], encoding: .ascii)
            let isValid = isPVD && signature == "CD001"

            // Volume Identifier ocupa bytes 40..71 (32 bytes ASCII)
            let rawLabel = String(bytes: sector[40..<72], encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
            let label = rawLabel.isEmpty ? url.deletingPathExtension().lastPathComponent : rawLabel

            let lower = (label + " " + url.lastPathComponent).lowercased()
            let arch: VMArchitecture?
            if lower.contains("arm64") || lower.contains("aarch64") {
                arch = .aarch64
            } else if lower.contains("amd64") || lower.contains("x86_64") || lower.contains("x64") {
                arch = .x86_64
            } else {
                arch = nil
            }

            return ISOInspectionResult(isValidISO9660: isValid, volumeLabel: label, detectedArchitecture: arch)
        } catch {
            return ISOInspectionResult(isValidISO9660: false, volumeLabel: url.deletingPathExtension().lastPathComponent, detectedArchitecture: nil)
        }
    }
}

