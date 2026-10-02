import Foundation
import OSLog

/// Why a `LibraryStore` could not be opened.
public enum LibraryStoreError: Error, Equatable, Sendable {
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returned nil:
    /// the App Group entitlement is missing or the identifier is invalid
    /// (ADR-0006). Thrown so the app fails loudly at startup rather than
    /// quietly keeping stickers somewhere else.
    case appGroupContainerUnavailable(String)
}

/// The per-device sticker library: `<uuid>.png` files plus an atomic
/// `index.json`, newest first (tech spec §4, ADR-0005).
///
/// Write ordering (FR-24), so a crash can leave an orphan PNG but never an
/// index entry without its image:
/// - Keep: PNG (`.atomic`), then index (`.atomic`).
/// - Delete: index (`.atomic`), then PNG.
/// - Launch: a missing index is an empty library; an undecodable one is set
///   aside as `index.corrupt-<timestamp>.json` and PNGs are never touched.
///
/// `keep` is the only write that adds a sticker and it takes a
/// `ProcessedSticker`, so a failed generation cannot reach the store.
public actor LibraryStore {
    /// The App Group shared by the shell app and the Messages extension.
    public static let appGroupIdentifier = "group.com.backhaushold.openmoji"

    private static let log = Logger(subsystem: "com.backhaushold.openmoji", category: "LibraryStore")
    private static let indexFileName = "index.json"

    private let root: URL
    private let files: any LibraryFileOperations
    /// Loaded on first use, then kept in step with disk by Keep and Delete.
    private var index: LibraryIndex?

    /// Rooted at an explicit directory, which is created on first use.
    /// Tests inject a temp directory; production uses `init(appGroupIdentifier:)`.
    public init(root: URL) {
        self.root = root
        self.files = DiskFileOperations()
    }

    /// Rooted at `<App Group container>/Library/Application Support/Stickers`.
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
            .appendingPathComponent("Stickers", isDirectory: true)
        self.files = DiskFileOperations()
    }

    /// Test seam: the same store over recording or failing file operations.
    init(root: URL, files: any LibraryFileOperations) {
        self.root = root
        self.files = files
    }

    /// Every kept sticker, newest first.
    public func stickers() throws -> [Sticker] {
        try loadedIndex().stickers
    }

    /// The PNG for `sticker`, for `MSSticker(contentsOfFileURL:)`.
    public nonisolated func fileURL(for sticker: Sticker) -> URL {
        root.appendingPathComponent(sticker.fileName)
    }

    /// Writes the PNG, then records it at the front of the index.
    ///
    /// If the index write fails the PNG is left behind as an orphan and the
    /// in-memory library does not change.
    @discardableResult
    public func keep(_ processed: ProcessedSticker, at date: Date = Date()) throws -> Sticker {
        var updated = try loadedIndex()
        let sticker = Sticker(
            id: UUID(),
            prompt: processed.prompt,
            // The index stores whole seconds (ISO 8601), so keep what we return equal to what we persist.
            createdAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)),
            modelID: processed.modelID,
            quality: processed.quality,
            pixelSize: processed.edge,
            byteCount: processed.png.count)

        try files.writeAtomically(processed.png, to: fileURL(for: sticker))
        updated.stickers.insert(sticker, at: 0)
        try write(updated)
        index = updated
        return sticker
    }

    /// Removes `id` from the index, then deletes its PNG. Unknown ids are a
    /// no-op.
    ///
    /// Once the index write succeeds the sticker is gone from the library; a
    /// failure to remove the PNG afterwards leaves a harmless orphan, which is
    /// logged rather than thrown (ADR-0005: v1 does not sweep orphans).
    public func delete(_ id: UUID) throws {
        var updated = try loadedIndex()
        guard let position = updated.stickers.firstIndex(where: { $0.id == id }) else { return }
        let removed = updated.stickers.remove(at: position)

        try write(updated)
        index = updated

        do {
            try files.remove(fileURL(for: removed))
        } catch {
            Self.log.error("Deleted a sticker from the index but could not remove its PNG: \(error.localizedDescription)")
        }
    }

    // MARK: - Index persistence

    private var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }

    private func loadedIndex() throws -> LibraryIndex {
        if let index { return index }
        try files.createDirectory(at: root)
        let loaded = try loadFromDisk()
        index = loaded
        return loaded
    }

    private func loadFromDisk() throws -> LibraryIndex {
        guard let data = try files.read(indexURL) else { return LibraryIndex() }
        do {
            return try LibraryIndex.makeDecoder().decode(LibraryIndex.self, from: data)
        } catch {
            // Never delete it and never overwrite it: move it aside first.
            let stamp = Date().formatted(Date.ISO8601FormatStyle(
                dateSeparator: .omitted, timeSeparator: .omitted, includingFractionalSeconds: true))
            let aside = root.appendingPathComponent("index.corrupt-\(stamp).json")
            Self.log.fault("index.json is undecodable (\(error.localizedDescription)); setting it aside as \(aside.lastPathComponent, privacy: .public)")
            try files.move(from: indexURL, to: aside)
            return LibraryIndex()
        }
    }

    private func write(_ updated: LibraryIndex) throws {
        try files.writeAtomically(LibraryIndex.makeEncoder().encode(updated), to: indexURL)
    }
}

extension LibraryIndex {
    /// Readable on disk (`index.json` is meant to be inspectable, ADR-0005).
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - File operations seam

/// The handful of file-system calls `LibraryStore` makes, so tests can record
/// their order and fail them. The write ordering is the point of the store.
protocol LibraryFileOperations: Sendable {
    func createDirectory(at url: URL) throws
    /// The file's contents, or nil if it does not exist.
    func read(_ url: URL) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Removes a file; already being gone is not an error.
    func remove(_ url: URL) throws
    func move(from source: URL, to destination: URL) throws
}

struct DiskFileOperations: LibraryFileOperations {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    func move(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
