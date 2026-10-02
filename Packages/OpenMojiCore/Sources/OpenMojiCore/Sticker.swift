import Foundation

/// One kept sticker's metadata (tech spec §4, FR-16). The PNG itself lives
/// beside the index as `fileName`.
public struct Sticker: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    /// As typed, at most 200 characters (FR-6).
    public let prompt: String
    public let createdAt: Date
    /// The model that produced it (FR-16).
    public let modelID: String
    /// e.g. "medium".
    public let quality: String
    /// Final edge length, 300...618.
    public let pixelSize: Int
    /// Final PNG size, under 500_000.
    public let byteCount: Int

    public var fileName: String { "\(id.uuidString).png" }

    public init(
        id: UUID,
        prompt: String,
        createdAt: Date,
        modelID: String,
        quality: String,
        pixelSize: Int,
        byteCount: Int
    ) {
        self.id = id
        self.prompt = prompt
        self.createdAt = createdAt
        self.modelID = modelID
        self.quality = quality
        self.pixelSize = pixelSize
        self.byteCount = byteCount
    }
}

/// The on-disk `index.json` (tech spec §4, ADR-0005).
public struct LibraryIndex: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Newest first.
    public var stickers: [Sticker]

    public init(schemaVersion: Int = LibraryIndex.currentSchemaVersion, stickers: [Sticker] = []) {
        self.schemaVersion = schemaVersion
        self.stickers = stickers
    }
}
