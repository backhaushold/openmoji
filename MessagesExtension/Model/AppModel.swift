import Messages
import Observation
import OpenMojiCore

/// The extension's state machine (tech spec §2, §10; ADR-0008).
///
/// `needsKey → idle → generating → preview → idle`, with a failed generation
/// landing in `failed(error, prompt)` and going back to `idle` with the prompt
/// intact (FR-23). Cancel returns to `idle` with no error (FR-10).
///
/// Nothing is persisted here: a generation in flight is simply lost if Messages
/// tears the extension down (FR-24). The API key is only ever checked for
/// presence; it is never read into state, logged or put in an error (NFR-6).
@MainActor
@Observable
final class AppModel {
    enum State: Equatable {
        /// No usable key: the expanded view opens Settings (FR-5).
        case needsKey
        /// Ready for a prompt.
        case idle
        /// A generation is in flight; cancelling the task cancels the request.
        case generating(Task<Void, Never>)
        /// A processed sticker awaiting Keep or Regenerate (FR-11, FR-12).
        case preview(ProcessedSticker)
        /// The generation failed. `prompt` is the text that was sent (FR-23).
        case failed(GenerationError, prompt: String)
    }

    private(set) var state: State

    /// The prompt draft, shared by Compose and Preview. A failure or a cancel
    /// never touches it (FR-23).
    var prompt = ""

    /// Mirrors the host's presentation style; set by `MessagesViewController`.
    var presentationStyle: MSMessagesAppPresentationStyle = .compact

    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let generator: any StickerGenerating
    /// Bumped whenever a generation starts or is abandoned, so a late result
    /// from an abandoned task is dropped.
    @ObservationIgnored private var generationID = 0

    init(credentials: any CredentialStore, generator: any StickerGenerating) {
        self.credentials = credentials
        self.generator = generator
        state = .idle
        refreshKey()
    }

    /// Re-reads whether a key is stored. No key (or an unreadable Keychain, as
    /// generating would fail the same way) routes to `needsKey` and abandons
    /// any generation; a key moves `needsKey` on to `idle`.
    func refreshKey() {
        if (try? credentials.load()) != nil {
            if state == .needsKey { state = .idle }
        } else {
            cancel()
            state = .needsKey
        }
    }

    /// Starts generating from `prompt`. Allowed from idle, preview
    /// (Regenerate) and failed (Try again); a blank prompt does nothing.
    func generate() {
        switch state {
        case .idle, .preview, .failed: break
        case .needsKey, .generating: return
        }
        let text = prompt
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        generationID += 1
        let id = generationID
        let generator = generator
        state = .generating(Task { [weak self] in
            let outcome: Result<ProcessedSticker, GenerationError>
            do throws(GenerationError) {
                outcome = try await .success(generator.generate(prompt: text))
            } catch {
                outcome = .failure(error)
            }
            self?.finishGeneration(id: id, prompt: text, outcome: outcome)
        })
    }

    /// Cancel (FR-10) and `willResignActive`: stops the request and goes back
    /// to the prompt with no error. Does nothing unless generating.
    func cancel() {
        guard case .generating(let task) = state else { return }
        generationID += 1
        task.cancel()
        state = .idle
    }

    /// Preview → idle, after Keep has written the sticker or the user walks
    /// away from it.
    func dismissPreview() {
        guard case .preview = state else { return }
        state = .idle
    }

    /// Failed → idle with `prompt` intact (FR-23).
    func dismissError() {
        guard case .failed = state else { return }
        state = .idle
    }

    private func finishGeneration(
        id: Int,
        prompt: String,
        outcome: Result<ProcessedSticker, GenerationError>
    ) {
        guard id == generationID, case .generating = state else { return }
        switch outcome {
        case .success(let sticker):
            state = .preview(sticker)
        case .failure(.cancelled):
            state = .idle
        case .failure(let error):
            state = .failed(error, prompt: prompt)
        }
    }
}
