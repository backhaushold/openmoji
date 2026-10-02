import Foundation
import OSLog

/// Turns transport errors and OpenAI error responses into `GenerationError`
/// (tech spec §6, FR-22). Rows are checked in table order.
///
/// Logging: `status`, `type` and `code` only. The mapper never sees the
/// prompt (log that `privacy: .private` where it is known) and never touches
/// the key or request headers (NFR-6).
public enum ErrorMapper {
    private static let logger = Logger(subsystem: "com.backhaushold.openmoji", category: "ErrorMapper")

    private static let billingCodes: Set<String> = [
        "credit_balance_exhausted",
        "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded",
        "organization_usage_limit_exceeded",
        "insufficient_quota",
    ]

    // MARK: Transport errors

    /// Maps a thrown error. Anything the §6 table doesn't list (other
    /// `URLError`s, unknown errors) is `.serviceUnavailable`. A
    /// `GenerationError` passes through unchanged.
    public static func map(_ error: any Error) -> GenerationError {
        if let generationError = error as? GenerationError { return generationError }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else {
            logger.error("transport error type=\(String(describing: type(of: error)), privacy: .public)")
            return .serviceUnavailable
        }
        logger.error("transport error URLError.code=\(urlError.code.rawValue, privacy: .public)")
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timeout
        default:
            return .serviceUnavailable
        }
    }

    // MARK: HTTP errors

    /// Maps a non-success HTTP response. `headers` are the response headers
    /// (only `Retry-After` is read); `body` is the raw
    /// `{"error": {"message", "type", "code", "param"}}` JSON, which may be
    /// empty or not JSON at all. `now` is only used to turn an HTTP-date
    /// `Retry-After` into seconds.
    public static func map(
        status: Int,
        headers: [String: String],
        body: Data,
        now: Date = Date()
    ) -> GenerationError {
        let fields = ErrorFields(body)
        logger.error("""
            OpenAI error status=\(status, privacy: .public) \
            type=\(fields.type ?? "-", privacy: .public) \
            code=\(fields.code ?? "-", privacy: .public)
            """)

        switch status {
        case 401:
            return .invalidKey
        case 403:
            return .keyNotPermitted(apiMessage: fields.message)
        case 429:
            // Billing 429s share the status with rate limits, so they go first.
            if fields.type == "insufficient_quota" || fields.code.map(billingCodes.contains) == true {
                return .budgetExhausted
            }
            return .rateLimited(retryAfter: retryAfter(in: headers, now: now))
        default:
            break
        }

        // The refusal status is undocumented, so type/code decide.
        if fields.code == "moderation_blocked" || fields.type == "image_generation_user_error" {
            return .contentRefused
        }
        if status == 404 || fields.code == "model_not_found" {
            return .modelUnavailable(apiMessage: fields.message)
        }
        if (500...599).contains(status) {
            return .serviceUnavailable
        }
        return .api(status: status, apiMessage: fields.message)
    }

    // MARK: Retry-After

    /// Whole seconds from a `Retry-After` header (delta-seconds or HTTP-date).
    /// `nil` when absent, unparseable or not in the future.
    private static func retryAfter(in headers: [String: String], now: Date) -> Int? {
        guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value
        else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)

        if !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            guard let seconds = Int(value), seconds > 0 else { return nil }
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        let seconds = Int(date.timeIntervalSince(now).rounded(.up))
        return seconds > 0 ? seconds : nil
    }

    // MARK: Body parsing

    /// The fields of an OpenAI error body. Missing, null or malformed
    /// fields are `nil`; a numeric `code` is read as its text.
    private struct ErrorFields {
        let message: String?
        let type: String?
        let code: String?

        init(_ body: Data) {
            let error = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let fields = error?["error"] as? [String: Any]
            message = Self.redactingKeys(Self.string(fields?["message"]))
            type = Self.string(fields?["type"])
            code = Self.string(fields?["code"])
        }

        private static func string(_ value: Any?) -> String? {
            switch value {
            case let string as String: return string
            case let number as NSNumber: return number.stringValue
            default: return nil
            }
        }

        /// OpenAI messages can echo a masked key ("Incorrect API key provided:
        /// sk-proj-****abcd"). Strip anything key-shaped so it can never reach
        /// a `GenerationError`, a log line or the UI (NFR-6).
        private static func redactingKeys(_ message: String?) -> String? {
            guard let message else { return nil }
            let redacted = message.replacing(/sk-[A-Za-z0-9_*\-]*/, with: "[redacted]")
            return redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : redacted
        }
    }
}
