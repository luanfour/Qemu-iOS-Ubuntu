import Foundation

/// Representa uma imagem ISO importada para o sandbox do aplicativo.
public struct ISOImage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var fileName: String
    public var displayName: String
    public var sizeBytes: Int64
    public var sha256Prefix: String
    public var volumeLabel: String
    public var isValidISO9660: Bool
    public var detectedArchitecture: VMArchitecture?
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        sizeBytes: Int64,
        sha256Prefix: String,
        volumeLabel: String = "Ubuntu Server",
        isValidISO9660: Bool = true,
        detectedArchitecture: VMArchitecture? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.sha256Prefix = sha256Prefix
        self.volumeLabel = volumeLabel
        self.isValidISO9660 = isValidISO9660
        self.detectedArchitecture = detectedArchitecture
        self.importedAt = importedAt
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

