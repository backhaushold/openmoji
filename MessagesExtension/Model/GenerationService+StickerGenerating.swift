import OpenMojiCore

/// `StickerGenerating` is the model's own seam and lives in the extension, so the
/// conformance does too. `GenerationService.generate(prompt:)` already has the
/// required signature.
extension GenerationService: StickerGenerating {}
