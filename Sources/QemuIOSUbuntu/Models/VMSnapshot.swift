import Foundation

/// Snapshot de disco/estado associado a uma máquina virtual.
public struct VMSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var vmId: UUID
    public var name: String
    public var notes: String
    public var fileName: String
    public var sizeBytes: Int64
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        vmId: UUID,
        name: String,
        notes: String = "",
        fileName: String,
        sizeBytes: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.vmId = vmId
        self.name = name
        self.notes = notes
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

