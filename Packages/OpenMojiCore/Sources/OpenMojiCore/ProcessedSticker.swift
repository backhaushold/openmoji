import Foundation

/// A generated sticker that has been through `makeSticker(from:)` and is
/// ready to preview and Keep (tech spec §2 flow, §7).
///
/// This is the only thing `LibraryStore.keep` accepts, so a failed
/// generation, which never produces one, cannot write to the store (FR-24).
public struct ProcessedSticker: Sendable, Equatable {
    /// The prompt as typed for this generation (FR-6).
    public let prompt: String
    /// The model that produced it (FR-16).
    public let modelID: String
    /// e.g. "medium".
    public let quality: String
    /// The final PNG, under 500_000 bytes.
    public let png: Data
    /// The PNG's edge length in pixels, 300...618.
    public let edge: Int

    public init(prompt: String, modelID: String, quality: String, png: Data, edge: Int) {
        self.prompt = prompt
        self.modelID = modelID
        self.quality = quality
        self.png = png
        self.edge = edge
    }
}
