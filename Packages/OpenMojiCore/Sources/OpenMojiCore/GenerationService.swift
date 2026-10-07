import Foundation
import OSLog

/// One call from a prompt to a sticker ready to preview and Keep
/// (tech spec §2 flow): load the key, moderate the prompt text, render the
/// style template, ask OpenAI, decode, turn the image into a
/// Messages-compliant PNG, and moderate that PNG (ADR-0019).
///
/// Every failure is a `GenerationError` (§6). It never touches `LibraryStore`:
/// a failed or cancelled generation produces no `ProcessedSticker`, so there is
/// nothing to write (FR-24), and the caller keeps the prompt (FR-23).
///
/// A `Sendable` struct, not an actor: it holds no mutable state, and the
/// caller (`AppModel`) already runs one generation at a time.
///
/// The key is read from `credentials` for each call, handed to the client and
/// dropped. It is never stored, logged or put in an error (NFR-6).
public struct GenerationService: Sendable {
    private static let logger = Logger(subsystem: "com.backhaushold.openmoji", category: "GenerationService")

    private let credentials: any CredentialStore
    private let client: OpenAIClient
    private let config: GenerationConfig
    private let process: @Sendable (Data) throws -> (png: Data, edge: Int)

    public init(
        credentials: any CredentialStore,
        client: OpenAIClient,
        config: GenerationConfig = GenerationConfig()
    ) {
        self.init(credentials: credentials, client: client, config: config) { try makeSticker(from: $0) }
    }

    /// `process` is a test seam: tests substitute it to see which thread the
    /// processing step runs on. Production always passes `makeSticker(from:)`.
    init(
        credentials: any CredentialStore,
        client: OpenAIClient,
        config: GenerationConfig,
        process: @escaping @Sendable (Data) throws -> (png: Data, edge: Int)
    ) {
        self.credentials = credentials
        self.client = client
        self.config = config
        self.process = process
    }

    /// Generates one sticker for `prompt`.
    ///
    /// `@concurrent` so none of it runs on the main actor, whatever actor the
    /// caller is on. The step that matters is processing (§7.2): ImageIO
    /// decodes, scales and re-encodes a ~2 MB PNG, up to once per ladder edge,
    /// which is enough CPU to drop frames if it ran on the main actor. The
    /// Keychain read is cheap but synchronous, so it moves off the main actor
    /// for free. Cancellation still propagates: `@concurrent` only changes
    /// where the function runs, not which task it is in.
    ///
    /// - Parameter prompt: The user's prompt as typed. The style template is
    ///   applied on the way out; the returned sticker keeps the user's text.
    /// - Throws: `.invalidKey` when there is no key, or the Keychain can't be
    ///   read: the spec doesn't say which case fits, and `.invalidKey` is the
    ///   one whose message ("Check it in Settings.") tells the user what to do.
    ///   `.cancelled` when the calling task is cancelled. `.contentRefused`
    ///   when the moderation check blocks the prompt (no image request is made)
    ///   or the generated image (it is dropped). A moderation call that fails
    ///   is that call's error from the client (§6): it fails closed, so
    ///   nothing is generated or returned. Every other case comes from the
    ///   client (§6), and `.processingFailed` from the image step.
    @concurrent
    public func generate(prompt: String) async throws(GenerationError) -> ProcessedSticker {
        try checkCancelled()
        let apiKey = try loadKey()

        // The free text check goes first, so a blocked prompt never reaches
        // the paid call. It screens the sanitised subject: the words the image
        // model will read from the user.
        let subject = StyleTemplate.sanitisedSubject(prompt)
        let promptVerdict = try await client.moderate(text: subject, apiKey: apiKey)
        try enforce(ModerationPolicy.decide(promptVerdict), on: "prompt")
        try checkCancelled()

        let encoded = try await client.generate(prompt: StyleTemplate.render(prompt), apiKey: apiKey)

        // A cancel that lands after the response skips the CPU-heavy step.
        try checkCancelled()
        let sticker: (png: Data, edge: Int)
        do {
            sticker = try process(encoded)
        } catch {
            // `makeSticker` only throws `.processingFailed`; anything else is
            // the same outcome to the user.
            throw .processingFailed
        }
        try checkCancelled()

        // The image is screened as the PNG the user would see and Keep.
        let imageVerdict = try await client.moderate(imagePNG: sticker.png, apiKey: apiKey)
        try enforce(ModerationPolicy.decide(imageVerdict), on: "image")
        try checkCancelled()

        return ProcessedSticker(
            prompt: prompt,
            modelID: config.model,
            quality: config.quality,
            png: sticker.png,
            edge: sticker.edge
        )
    }

    /// Turns a blocking decision into `.contentRefused`. The log carries the
    /// stage and OpenAI's category names, never the prompt or the key.
    private func enforce(_ decision: ModerationDecision, on stage: String) throws(GenerationError) {
        guard case .block(let reasons) = decision else { return }
        // openmoji-6dr.4 (parental prompt log): a blocked prompt is the one a
        // parent most wants to see, so record it here when that lands.
        Self.logger.notice("""
            moderation blocked the \(stage, privacy: .public) \
            categories=\(reasons.joined(separator: ","), privacy: .public)
            """)
        throw .contentRefused
    }

    private func checkCancelled() throws(GenerationError) {
        if Task.isCancelled { throw .cancelled }
    }

    private func loadKey() throws(GenerationError) -> String {
        do {
            if let key = try credentials.load() {
                return key
            }
        } catch {
            // `CredentialStoreError` carries at most an `OSStatus`; log neither it nor
            // anything else about the store.
            Self.logger.error("could not read the API key")
            throw .invalidKey
        }
        Self.logger.error("no API key stored")
        throw .invalidKey
    }
}
