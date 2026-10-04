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
        /// No usable key: the library shows "Set up OpenMoji" in place of "New
        /// sticker" (FR-5, NFR-10).
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

    /// The most characters a prompt may have (FR-6). Counted as `Character`s,
    /// i.e. extended grapheme clusters, so what the user sees as one character
    /// (an emoji with a skin tone or a ZWJ family, a letter with a combining
    /// accent, CRLF) counts once. The spec doesn't say; this is the unit the
    /// user can see and count. It also means truncation never splits a cluster.
    static let promptLimit = 200

    /// The prompt draft, shared by Compose and Preview. A failure or a cancel
    /// never touches it (FR-23). It never holds more than `promptLimit`
    /// characters: a longer value, such as a paste, is cut to the limit.
    var prompt = "" {
        didSet {
            if prompt.count > Self.promptLimit {
                prompt = String(prompt.prefix(Self.promptLimit))
            }
        }
    }

    /// The Compose counter's value: how many characters `prompt` has.
    var promptCount: Int { prompt.count }

    /// Whether Generate is enabled: a state that can start a generation (idle,
    /// or Regenerate / Try again) and a prompt that isn't empty or only
    /// whitespace.
    var canGenerate: Bool {
        switch state {
        case .idle, .preview, .failed: break
        case .needsKey, .generating: return false
        }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Asks the host for the expanded presentation style. Set by
    /// `MessagesViewController` (`requestPresentationStyle(.expanded)`); a
    /// closure so the model stays testable without a view controller.
    @ObservationIgnored var requestExpandedStyle: @MainActor () -> Void = {}

    /// Mirrors the host's presentation style; set by `MessagesViewController`.
    var presentationStyle: MSMessagesAppPresentationStyle = .compact

    /// Whether the user has opened Compose from the library (ADR-0017). Expanded
    /// and idle shows the library until then; once set, idle shows Compose, so
    /// Cancel, a failure and Edit description all come back to the prompt.
    /// Back (`closeCompose()`) and having no key clear it.
    private(set) var isComposing = false

    /// What `RootView` shows, from the state and the presentation style (tech
    /// spec §8 Routing, §10; FR-5, ADR-0017). Sending stickers needs no key, so
    /// the library shows with or without one; only its action changes (NFR-10).
    enum Route: Equatable {
        /// Compact, ready: the library and "New sticker".
        case compactHome
        /// Compact, no key: the library and "Set up OpenMoji".
        case compactSetUp
        /// Expanded, ready: the library, the landing screen, and "New sticker".
        case library
        /// Expanded, no key: the library and "Set up OpenMoji", which opens
        /// Settings.
        case librarySetUp
        /// Expanded, ready, after "New sticker": the prompt.
        case compose
        /// Generating adapts to the style inside its view (one view, so it
        /// keeps its state when the host expands or collapses), and so does the
        /// error. Preview looks the same in both styles for now.
        case generating
        case preview
        case failed(GenerationError)
    }

    var route: Route {
        let expanded = presentationStyle == .expanded
        switch state {
        case .needsKey: return expanded ? .librarySetUp : .compactSetUp
        case .idle: return expanded ? (isComposing ? .compose : .library) : .compactHome
        case .generating: return .generating
        case .preview: return .preview
        case .failed(let error, _): return .failed(error)
        }
    }

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

    /// Re-reads whether a key is stored; `MessagesViewController` calls it on
    /// `willBecomeActive` (FR-5), so a key saved or cleared since the last time
    /// the extension was active is picked up. No key (or an unreadable Keychain, as
    /// generating would fail the same way) routes to `needsKey`, abandons
    /// any generation and leaves Compose; a key moves `needsKey` on to `idle`,
    /// the library.
    func refreshKey() {
        if (try? credentials.load()) != nil {
            if state == .needsKey { state = .idle }
        } else {
            cancel()
            state = .needsKey
            isComposing = false
        }
    }

    /// The library's "New sticker": opens Compose. Text entry only happens in
    /// expanded, so in compact it also asks the host to expand, and Compose
    /// shows once the host reports it (tech spec §10).
    func startNewSticker() {
        isComposing = true
        if presentationStyle != .expanded { requestExpandedStyle() }
    }

    /// Compose's back button: returns to the library with the prompt kept.
    /// Only from the prompt itself; the other screens have their own exits.
    func closeCompose() {
        guard state == .idle else { return }
        isComposing = false
    }

    /// Compact's "Set up OpenMoji" (no key): Settings is in expanded, so ask
    /// the host to expand. Expanded with no key shows the library with its own
    /// "Set up OpenMoji", which opens Settings.
    func startSetUp() {
        requestExpandedStyle()
    }

    /// Starts generating from `prompt`. Allowed from idle, preview
    /// (Regenerate) and failed (Try again); a blank prompt does nothing
    /// (see `canGenerate`).
    func generate() {
        guard canGenerate else { return }
        let text = prompt
        isComposing = true

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
