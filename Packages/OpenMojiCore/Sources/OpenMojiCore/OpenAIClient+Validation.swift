import Foundation

/// The outcome of checking a candidate API key before saving it
/// (tech spec §5.4, ADR-0009, FR-4).
///
/// A closed set with no payloads, so nothing in it can carry the key or an
/// echo of it from the API (NFR-6). The UI owns the user-facing wording.
public enum KeyValidationResult: Equatable, Sendable {
    /// 200: the key is valid and the image model is visible.
    case valid
    /// 404, or 403 with error code `model_not_found` (reported for
    /// project-scoped keys without model access): the key is valid but the
    /// model is not visible (org not verified, or a wrong model ID). Save,
    /// with a warning.
    case modelNotVisible
    /// 401: not a valid key. Do not save.
    case invalid
    /// Any other 403: the key lacks "List models: Read", or the org or region
    /// is not permitted. Do not save.
    case notPermitted
    /// Offline, timeout, or any response that gives no verdict on the key
    /// (429, 5xx, other statuses). Offer "Save anyway".
    case couldNotCheck

    /// Whether the key is saved without asking the user (§5.4 "Save?" column).
    public var allowsSaving: Bool {
        switch self {
        case .valid, .modelNotVisible: true
        case .invalid, .notPermitted, .couldNotCheck: false
        }
    }

    /// Whether the UI offers "Save anyway".
    public var offersSaveAnyway: Bool { self == .couldNotCheck }
}

extension OpenAIClient {
    /// Checks `key` with `GET /v1/models/{configured model ID}` before it is
    /// saved (§5.4). Never throws: every outcome is a `KeyValidationResult`.
    ///
    /// No retries. The status mapping is exactly §5.4; statuses it does not
    /// list, transport failures and a cancelled task all mean the key could
    /// not be checked.
    ///
    /// The key goes on this request's `Authorization` header only. It is never
    /// stored, logged, or put in the result (NFR-6).
    public func validate(key: String) async -> KeyValidationResult {
        guard let request = makeValidationRequest(key: key) else {
            return .couldNotCheck
        }
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .couldNotCheck }
            switch http.statusCode {
            case 200: return .valid
            case 401: return .invalid
            case 403: return Self.errorCode(in: body) == "model_not_found" ? .modelNotVisible : .notPermitted
            case 404: return .modelNotVisible
            default: return .couldNotCheck
            }
        } catch {
            return .couldNotCheck
        }
    }

    /// `error.code` from an OpenAI error body, or `nil` when the body is not
    /// that shape. Only this one field is read, so nothing the API echoes
    /// back (the message can quote a masked key) is kept (NFR-6).
    private static func errorCode(in body: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (object?["error"] as? [String: Any])?["code"] as? String
    }

    private func makeValidationRequest(key: String) -> URLRequest? {
        // The model ID is one path component, so `/`, `?` and `#` are escaped too.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let component = config.model.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.openai.com/v1/models/\(component)")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
}
