import Foundation

/// The closed set of ways a generation can fail (tech spec §6, FR-22).
///
/// One plain user message per case. No case carries request headers or the
/// API key: `apiMessage` payloads are produced by `ErrorMapper`, which strips
/// anything shaped like a key (NFR-6).
public enum GenerationError: Error, Equatable, Sendable {
    /// The user (or task) cancelled. No message; return to the prompt.
    case cancelled
    case offline
    case timeout
    case invalidKey
    case keyNotPermitted(apiMessage: String?)
    /// A billing 429: credit, spend or usage limit reached.
    case budgetExhausted
    /// Any other 429. `retryAfter` is whole seconds from `Retry-After`.
    case rateLimited(retryAfter: Int?)
    case contentRefused
    case modelUnavailable(apiMessage: String?)
    case serviceUnavailable
    case api(status: Int, apiMessage: String?)
    case processingFailed

    /// The one plain message the UI shows, or `nil` when the UI shows none
    /// (`.cancelled`).
    public var userMessage: String? {
        switch self {
        case .cancelled:
            return nil
        case .offline:
            return "You're offline. Your stickers still work; making new ones needs internet."
        case .timeout:
            return "That took too long. Try again."
        case .invalidKey:
            return "The OpenAI key isn't working. Check it in Settings."
        case .keyNotPermitted(let apiMessage):
            return Self.append(apiMessage, to: "This key isn't allowed to make images.")
        case .budgetExhausted:
            return "The sticker budget is used up. Ask the family admin to top it up."
        case .rateLimited(let retryAfter):
            guard let seconds = retryAfter else {
                return "Too many stickers at once. Try again in a moment."
            }
            let unit = seconds == 1 ? "second" : "seconds"
            return "Too many stickers at once. Try again in \(seconds) \(unit)."
        case .contentRefused:
            return "OpenAI won't make that one. Try wording it differently."
        case .modelUnavailable(let apiMessage):
            return Self.append(apiMessage, to: "The image model isn't available on this account.")
        case .serviceUnavailable:
            return "OpenAI is having trouble. Try again shortly."
        case .api(_, let apiMessage):
            guard let apiMessage else { return "Something went wrong." }
            return "Something went wrong: \(apiMessage)"
        case .processingFailed:
            return "Couldn't turn that into a sticker. Try again."
        }
    }

    private static func append(_ apiMessage: String?, to base: String) -> String {
        guard let apiMessage else { return base }
        return "\(base) \(apiMessage)"
    }
}

extension GenerationError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
