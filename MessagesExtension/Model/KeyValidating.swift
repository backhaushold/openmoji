import OpenMojiCore

/// What `SettingsModel` needs from key validation: one call from a candidate
/// key to a verdict (tech spec §5.4, FR-4).
///
/// The model's own seam for fakes, like `StickerGenerating`. Implementations
/// must not log the key or keep it (NFR-6).
protocol KeyValidating: Sendable {
    func validate(key: String) async -> KeyValidationResult
}

extension OpenAIClient: KeyValidating {}
