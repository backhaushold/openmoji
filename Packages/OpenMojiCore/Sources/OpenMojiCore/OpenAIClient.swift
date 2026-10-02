import Foundation
import OSLog

/// Plain `URLSession` client for `POST /v1/images/generations`
/// (tech spec §5, ADR-0002, ADR-0003). No SDK, no retries: every attempt
/// costs money, so a retry is the user's Regenerate (D3, D7).
///
/// Every failure is a `GenerationError`: HTTP errors and transport errors go
/// through `ErrorMapper`, and an undecodable success body is
/// `.processingFailed` (§6). Cancelling the calling `Task` cancels the
/// underlying data task and throws `.cancelled`.
///
/// The key is passed per call and set on that request's `Authorization`
/// header only. It is never stored, logged or put in an error (NFR-6).
public actor OpenAIClient {
    private static let logger = Logger(subsystem: "com.backhaushold.openmoji", category: "OpenAIClient")

    static let endpoint = URL(string: "https://api.openai.com/v1/images/generations")!

    /// NFR-4: ErrorMapper relies on these surfacing as `URLError.timedOut`.
    static let timeout: TimeInterval = 90

    /// Internal so tests can read the timeouts and cache settings it was built with.
    nonisolated let session: URLSession
    /// Internal so `validate(key:)` (OpenAIClient+Validation.swift) can read the model ID.
    let config: GenerationConfig

    public init(config: GenerationConfig = GenerationConfig()) {
        self.init(config: config, protocolClasses: nil)
    }

    /// `protocolClasses` lets tests put a `URLProtocol` stub in front of the network.
    init(config: GenerationConfig, protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        self.session = URLSession(configuration: configuration)
        self.config = config
    }

    /// Generates one transparent PNG for `prompt` and returns its bytes.
    ///
    /// - Parameters:
    ///   - prompt: The fully rendered prompt (style template applied).
    ///   - apiKey: The OpenAI API key, read from the Keychain by the caller.
    public func generate(prompt: String, apiKey: String) async throws(GenerationError) -> Data {
        let request: URLRequest
        do {
            request = try makeRequest(prompt: prompt, apiKey: apiKey)
        } catch {
            Self.logger.error("could not encode request")
            throw .processingFailed
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ErrorMapper.map(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ErrorMapper.map(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
                if let name = field.key as? String, let value = field.value as? String {
                    result[name] = value
                }
            }
            throw ErrorMapper.map(status: http.statusCode, headers: headers, body: data)
        }
        return try Self.decodeImage(from: data)
    }

    // MARK: Request (§5.1)

    private func makeRequest(prompt: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: config.model, prompt: prompt, quality: config.quality)
        )
        return request
    }

    /// Exactly the §5.1 fields. `response_format`, `partial_images` and
    /// `user` are deliberately absent.
    private struct RequestBody: Encodable {
        let model: String
        let prompt: String
        let n = 1
        let size = "1024x1024"
        let quality: String
        let background = "transparent"
        let outputFormat = "png"
        let moderation = "auto"

        init(model: String, prompt: String, quality: String) {
            self.model = model
            self.prompt = prompt
            self.quality = quality
        }

        enum CodingKeys: String, CodingKey {
            case model, prompt, n, size, quality, background, moderation
            case outputFormat = "output_format"
        }
    }

    // MARK: Response (§5.2)

    private static func decodeImage(from body: Data) throws(GenerationError) -> Data {
        guard let response = try? JSONDecoder().decode(ImageResponse.self, from: body) else {
            logger.error("success body is not a decodable image response")
            throw .processingFailed
        }
        #if DEBUG
        if let usage = response.usage {
            logger.debug("""
                usage input=\(usage.inputTokens ?? -1, privacy: .public) \
                output=\(usage.outputTokens ?? -1, privacy: .public) \
                total=\(usage.totalTokens ?? -1, privacy: .public)
                """)
        }
        #endif
        guard let encoded = response.data?.first?.b64Json,
              let image = Data(base64Encoded: encoded),
              !image.isEmpty
        else {
            logger.error("success body has no usable data[0].b64_json")
            throw .processingFailed
        }
        return image
    }

    /// Only the fields we use. `usage` is optional and never fails the decode.
    private struct ImageResponse: Decodable {
        struct Item: Decodable {
            let b64Json: String?

            enum CodingKeys: String, CodingKey { case b64Json = "b64_json" }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                b64Json = try? container.decodeIfPresent(String.self, forKey: .b64Json)
            }
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let totalTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case totalTokens = "total_tokens"
            }
        }

        let data: [Item]?
        let usage: Usage?

        enum CodingKeys: String, CodingKey { case data, usage }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            data = try container.decodeIfPresent([Item].self, forKey: .data)
            usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
        }
    }
}
