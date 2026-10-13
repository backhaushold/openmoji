import Foundation

/// One line of the audit log: a prompt as typed and when its generation was
/// asked for.
public struct PromptLogEntry: Codable, Equatable, Sendable {
    public let at: Date
    public let prompt: String

    public init(at: Date, prompt: String) {
        self.at = at
        self.prompt = prompt
    }
}

/// The per-device audit log of generation prompts, for parental review
/// (ADR-0020): one JSON object per line in `prompts.jsonl`, oldest first.
///
/// Append-only: `record` adds a line at the end and nothing here rewrites,
/// trims or deletes the file. It holds prompts and dates only, never the API
/// key (NFR-6).
public actor PromptLog {
    private static let fileName = "prompts.jsonl"
    private static let newline = UInt8(ascii: "\n")

    private let root: URL

    /// Rooted at an explicit directory, which is created on first use.
    /// Tests inject a temp directory; production uses `init(appGroupIdentifier:)`.
    public init(root: URL) {
        self.root = root
    }

    /// Rooted at `<App Group container>/Library/Application Support/PromptLog`.
    ///
    /// - Throws: `LibraryStoreError.appGroupContainerUnavailable` if the group
    ///   container cannot be resolved.
    public init(
        appGroupIdentifier: String = LibraryStore.appGroupIdentifier,
        containerURL: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    ) throws {
        guard let container = containerURL(appGroupIdentifier) else {
            throw LibraryStoreError.appGroupContainerUnavailable(appGroupIdentifier)
        }
        self.root = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PromptLog", isDirectory: true)
    }

    private var fileURL: URL {
        root.appendingPathComponent(Self.fileName)
    }

    /// Appends `prompt` with `date` as one line.
    public func record(_ prompt: String, at date: Date = Date()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // JSON escapes a newline inside the prompt, so an entry is always one line.
        var line = try encoder.encode(PromptLogEntry(at: date, prompt: prompt))
        line.append(Self.newline)

        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Every entry, oldest first. No file yet is an empty log. A line that
    /// doesn't decode (a write cut short by a crash) is skipped, so one bad
    /// line never hides the rest.
    public func entries() throws -> [PromptLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: fileURL)
            .split(separator: Self.newline)
            .compactMap { try? decoder.decode(PromptLogEntry.self, from: $0) }
    }
}
