import Foundation
import OSLog

extension OpenAIClient {
    private static let moderationLogger = Logger(
        subsystem: "com.backhaushold.openmoji", category: "OpenAIClient.moderation"
    )

    static let moderationEndpoint = URL(string: "https://api.openai.com/v1/moderations")!

    /// The alias, not a dated snapshot; the endpoint is free (tech spec §5.5).
    static let moderationModel = "omni-moderation-latest"

    /// Classifies `text` with `POST /v1/moderations` (tech spec §5.5,
    /// ADR-0019). Returns the verdict; whether to block is
    /// `ModerationPolicy`'s call, not the client's.
    ///
    /// No retries. Fails closed: every failure (transport, HTTP error, or a
    /// success body with no usable verdict) is a `GenerationError`, so the
    /// caller never treats "couldn't check" as "fine". An undecodable verdict
    /// is `.serviceUnavailable`.
    ///
    /// The key goes on this request's `Authorization` header only. Neither it
    /// nor `text` is logged or put in an error (NFR-6).
    public func moderate(text: String, apiKey: String) async throws(GenerationError) -> ModerationResult {
        try await moderate(input: text, apiKey: apiKey)
    }

    /// Classifies a PNG with `POST /v1/moderations`, sent as a base64 `data:`
    /// URL (docs: images up to 20 MB). Same contract as `moderate(text:apiKey:)`.
    public func moderate(imagePNG: Data, apiKey: String) async throws(GenerationError) -> ModerationResult {
        let url = "data:image/png;base64," + imagePNG.base64EncodedString()
        return try await moderate(input: [ImagePart(imageURL: .init(url: url))], apiKey: apiKey)
    }

    private func moderate(input: some Encodable, apiKey: String) async throws(GenerationError) -> ModerationResult {
        var request = URLRequest(url: Self.moderationEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(ModerationRequestBody(input: input))
        } catch {
            Self.moderationLogger.error("could not encode moderation request")
            throw .serviceUnavailable
        }

        let body = try await send(request)
        guard let result = try? JSONDecoder().decode(ModerationResponse.self, from: body).results.first?.result else {
            Self.moderationLogger.error("success body has no usable results[0]")
            throw .serviceUnavailable
        }
        return result
    }

    // MARK: Request

    /// One `image_url` content part; an image's `input` is an array of one.
    private struct ImagePart: Encodable {
        struct ImageURL: Encodable { let url: String }
        let type = "image_url"
        let imageURL: ImageURL

        enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
        }
    }

    /// `input` is a bare string for text, `[ImagePart]` for an image.
    private struct ModerationRequestBody<Input: Encodable>: Encodable {
        let model = OpenAIClient.moderationModel
        let input: Input
    }

    // MARK: Response

    /// `results[0]` only. `flagged`, `categories` and `category_scores` are all
    /// required: a body missing any of them gives no verdict. A category flag
    /// or score that is `null` is dropped (the reference marks `illicit` and
    /// `illicit/violent` nullable); unknown categories are kept.
    private struct ModerationResponse: Decodable {
        struct Item: Decodable {
            let flagged: Bool
            let categories: [String: Bool?]
            let categoryScores: [String: Double?]

            enum CodingKeys: String, CodingKey {
                case flagged, categories
                case categoryScores = "category_scores"
            }

            var result: ModerationResult {
                ModerationResult(
                    flagged: flagged,
                    categories: categories.compactMapValues { $0 },
                    categoryScores: categoryScores.compactMapValues { $0 }
                )
            }
        }

        let results: [Item]
    }
}
