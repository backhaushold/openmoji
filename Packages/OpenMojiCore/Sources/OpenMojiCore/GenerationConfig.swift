import Foundation

/// Configuration for the image generation request: model ID and quality.
/// Read once from Info.plist at initialization, with compiled-in fallbacks
/// (tech spec §3, FR-9, ADR-0013).
public struct GenerationConfig: Sendable {
    /// The OpenAI image model ID (e.g., `gpt-image-2.5-flare`).
    public let model: String

    /// The image quality (e.g., `medium`).
    public let quality: String

    /// Reads `OpenMojiImageModel` and `OpenMojiImageQuality` from the given
    /// info dictionary. Missing or empty values use the compiled-in fallbacks.
    ///
    /// - Parameters:
    ///   - infoDictionary: The dictionary to read keys from (typically
    ///     `Bundle.main.infoDictionary`). If `nil`, uses empty dictionary
    ///     and all values fall back to defaults.
    public init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        let dict = infoDictionary ?? [:]

        // Read OpenMojiImageModel, fallback to gpt-image-2.5-flare
        if let modelValue = dict["OpenMojiImageModel"] as? String,
           !modelValue.trimmingCharacters(in: .whitespaces).isEmpty {
            self.model = modelValue
        } else {
            self.model = "gpt-image-2.5-flare"
        }

        // Read OpenMojiImageQuality, fallback to medium
        if let qualityValue = dict["OpenMojiImageQuality"] as? String,
           !qualityValue.trimmingCharacters(in: .whitespaces).isEmpty {
            self.quality = qualityValue
        } else {
            self.quality = "medium"
        }
    }
}
