import OpenMojiCore

/// What `AppModel` needs from generation: one call from prompt to a processed
/// sticker (tech spec §2 flow).
///
/// Defined here, not in `OpenMojiCore`, because it is the model's own seam for
/// fakes. `GenerationService` conforms to it (GenerationService+StickerGenerating.swift)
/// and is wired in `MessagesViewController`.
///
/// Implementations should stop when the calling task is cancelled (FR-10),
/// throwing `.cancelled`.
protocol StickerGenerating: Sendable {
    func generate(prompt: String) async throws(GenerationError) -> ProcessedSticker
}
