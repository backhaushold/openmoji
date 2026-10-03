import OpenMojiCore

extension GenerationError {
    /// Whether the error view adds a Settings button (tech spec §6): only a
    /// rejected key, whose message points at Settings. Exhaustive on purpose,
    /// so a new case has to decide.
    var offersSettings: Bool {
        switch self {
        case .invalidKey:
            true
        case .cancelled, .offline, .timeout, .keyNotPermitted, .budgetExhausted,
             .rateLimited, .contentRefused, .modelUnavailable, .serviceUnavailable,
             .api, .processingFailed:
            false
        }
    }
}
