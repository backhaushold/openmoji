import Foundation
import OpenMojiCore

/// What `AppModel` needs from the audit log (ADR-0020): add a prompt, and
/// read them all back for Settings.
///
/// The model's own seam for fakes, like `StickerLibrary`. `PromptLog` conforms
/// to it and is wired in `MessagesViewController`.
protocol PromptLogging: Sendable {
    /// Appends `prompt`, dated now.
    func record(_ prompt: String) async throws
    /// Every entry, oldest first.
    func entries() async throws -> [PromptLogEntry]
}

/// `PromptLog.entries()` already has the required signature. Its own
/// `record(_:at:)` takes the date, which a generation sets to now.
extension PromptLog: PromptLogging {
    func record(_ prompt: String) async throws {
        try record(prompt, at: Date())
    }
}
