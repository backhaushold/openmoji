import Foundation
import Synchronization
import Testing
@testable import OpenMojiCore

// MARK: - Test doubles and helpers

/// Wraps the real disk operations, records every mutating call in order, and
/// can fail the calls a test picks. This is how the Keep/Delete write
/// ordering (FR-24) is asserted rather than assumed.
private final class RecordingFileOperations: LibraryFileOperations, Sendable {
    enum Event: Equatable {
        case write(String)
        case remove(String)
        case move(from: String, to: String)
    }

    struct Injected: Error {}

    private let disk = DiskFileOperations()
    private let state = Mutex<[Event]>([])
    private let shouldFail: @Sendable (Event) -> Bool

    init(failing shouldFail: @escaping @Sendable (Event) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }

    var events: [Event] { state.withLock { $0 } }

    private func record(_ event: Event) throws {
        state.withLock { $0.append(event) }
        if shouldFail(event) { throw Injected() }
    }

    func createDirectory(at url: URL) throws {
        try disk.createDirectory(at: url)
    }

    func read(_ url: URL) throws -> Data? {
        try disk.read(url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try record(.write(url.lastPathComponent))
        try disk.writeAtomically(data, to: url)
    }

    func remove(_ url: URL) throws {
        try record(.remove(url.lastPathComponent))
        try disk.remove(url)
    }

    func move(from source: URL, to destination: URL) throws {
        try record(.move(from: source.lastPathComponent, to: destination.lastPathComponent))
        try disk.move(from: source, to: destination)
    }
}

/// A unique, not-yet-created directory under the system temp dir, removed
/// when `body` returns. The store must create it (and parents) itself.
private func withTempRoot(_ body: (URL) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try await body(base.appendingPathComponent("Library/Application Support/Stickers", isDirectory: true))
}

private func processed(
    _ prompt: String = "a happy cat",
    png: Data = Data([0x89, 0x50, 0x4E, 0x47, 0x01]),
    edge: Int = 618
) -> ProcessedSticker {
    ProcessedSticker(prompt: prompt, modelID: "gpt-image-1-mini", quality: "medium", png: png, edge: edge)
}

private func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func corruptFiles(in directory: URL) throws -> [URL] {
    try names(in: directory)
        .filter { $0.hasPrefix("index.corrupt-") && $0.hasSuffix(".json") }
        .map { directory.appendingPathComponent($0) }
}

// MARK: - Keep

@Suite struct LibraryStoreKeepTests {
    @Test func keepRecordsTheStickerMetadataFromTheProcessedSticker() async throws {
        try await withTempRoot { root in
            let store = LibraryStore(root: root)
            let png = Data(repeating: 7, count: 1_234)
            let when = Date(timeIntervalSince1970: 1_800_000_000)

            let kept = try await store.keep(processed("hello", png: png, edge: 512), at: when)

            #expect(kept.prompt == "hello")
            #expect(kept.modelID == "gpt-image-1-mini")
            #expect(kept.quality == "medium")
            #expect(kept.pixelSize == 512)
            #expect(kept.byteCount == 1_234)
            #expect(kept.createdAt == when)
            #expect(kept.fileName == "\(kept.id.uuidString).png")
            #expect(try await store.stickers() == [kept])
        }
    }

    @Test func keepWritesTheLayoutFromTheTechSpec() async throws {
        try await withTempRoot { root in
            let store = LibraryStore(root: root)
            let png = Data([1, 2, 3, 4])

            let kept = try await store.keep(processed(png: png))

            #expect(try names(in: root) == ["index.json", kept.fileName].sorted())
            #expect(try Data(contentsOf: root.appendingPathComponent(kept.fileName)) == png)
            #expect(store.fileURL(for: kept) == root.appendingPathComponent(kept.fileName))

            let index = try LibraryIndex.makeDecoder().decode(
                LibraryIndex.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
            #expect(index.schemaVersion == 1)
            #expect(index.stickers == [kept])
        }
    }

    @Test func keepWritesThePNGBeforeTheIndex() async throws {
        try await withTempRoot { root in
            let files = RecordingFileOperations()
            let store = LibraryStore(root: root, files: files)

            let kept = try await store.keep(processed())

            #expect(files.events == [.write(kept.fileName), .write("index.json")])
        }
    }

    @Test func aFailedIndexWriteLeavesAnOrphanPNGNeverADanglingEntry() async throws {
        try await withTempRoot { root in
            let files = RecordingFileOperations(failing: { $0 == .write("index.json") })
            let store = LibraryStore(root: root, files: files)

            await #expect(throws: RecordingFileOperations.Injected.self) {
                try await store.keep(processed())
            }

            // The in-memory view did not advance, and a fresh process sees
            // an empty library with one harmless orphan PNG.
            #expect(try await store.stickers().isEmpty)
            let fresh = LibraryStore(root: root)
            #expect(try await fresh.stickers().isEmpty)
            let onDisk = try names(in: root)
            #expect(onDisk.count == 1 && onDisk[0].hasSuffix(".png"))
        }
    }

    @Test func aFailedPNGWriteNeverTouchesTheIndex() async throws {
        try await withTempRoot { root in
            let files = RecordingFileOperations(failing: { event in
                if case .write(let name) = event { return name.hasSuffix(".png") }
                return false
            })
            let store = LibraryStore(root: root, files: files)

            await #expect(throws: RecordingFileOperations.Injected.self) {
                try await store.keep(processed())
            }

            let stickers = try await store.stickers()
            #expect(stickers.isEmpty)
            #expect(try names(in: root).isEmpty)
        }
    }

    @Test func newestIsFirstAndOrderIsPersisted() async throws {
        try await withTempRoot { root in
            let store = LibraryStore(root: root)
            let first = try await store.keep(processed("one"))
            let second = try await store.keep(processed("two"))
            let third = try await store.keep(processed("three"))

            #expect(try await store.stickers().map(\.id) == [third.id, second.id, first.id])

            let index = try LibraryIndex.makeDecoder().decode(
                LibraryIndex.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
            #expect(index.stickers.map(\.id) == [third.id, second.id, first.id])
        }
    }
}

// MARK: - Delete

@Suite struct LibraryStoreDeleteTests {
    @Test func deleteWritesTheIndexBeforeRemovingThePNG() async throws {
        try await withTempRoot { root in
            let files = RecordingFileOperations()
            let store = LibraryStore(root: root, files: files)
            let kept = try await store.keep(processed())

            try await store.delete(kept.id)

            #expect(files.events == [
                .write(kept.fileName), .write("index.json"),   // keep
                .write("index.json"), .remove(kept.fileName),  // delete
            ])
            #expect(try await store.stickers().isEmpty)
            #expect(try names(in: root) == ["index.json"])
        }
    }

    @Test func deleteLeavesOtherStickersUntouched() async throws {
        try await withTempRoot { root in
            let store = LibraryStore(root: root)
            let first = try await store.keep(processed("one", png: Data([1])))
            let second = try await store.keep(processed("two", png: Data([2])))
            let third = try await store.keep(processed("three", png: Data([3])))

            try await store.delete(second.id)

            #expect(try await store.stickers() == [third, first])
            #expect(try Data(contentsOf: root.appendingPathComponent(first.fileName)) == Data([1]))
            #expect(try Data(contentsOf: root.appendingPathComponent(third.fileName)) == Data([3]))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(second.fileName).path))
        }
    }

    @Test func aFailedIndexWriteLeavesTheStickerAndItsPNGIntact() async throws {
        try await withTempRoot { root in
            let counter = Mutex(0)
            // Let Keep's index write through, fail the Delete's.
            let files = RecordingFileOperations(failing: { event in
                guard event == .write("index.json") else { return false }
                return counter.withLock { $0 += 1; return $0 == 2 }
            })
            let store = LibraryStore(root: root, files: files)
            let kept = try await store.keep(processed())

            await #expect(throws: RecordingFileOperations.Injected.self) {
                try await store.delete(kept.id)
            }

            #expect(try await store.stickers() == [kept])
            #expect(files.events.last == .write("index.json"))  // never reached the PNG
            #expect(try await LibraryStore(root: root).stickers() == [kept])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept.fileName).path))
        }
    }

    @Test func aFailedPNGRemovalStillDeletesTheStickerFromTheLibrary() async throws {
        try await withTempRoot { root in
            let files = RecordingFileOperations(failing: { event in
                if case .remove = event { return true }
                return false
            })
            let store = LibraryStore(root: root, files: files)
            let kept = try await store.keep(processed())

            try await store.delete(kept.id)  // the orphan PNG is logged, not fatal

            #expect(try await store.stickers().isEmpty)
            #expect(try await LibraryStore(root: root).stickers().isEmpty)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept.fileName).path))
        }
    }

    @Test func deletingAnUnknownIDChangesNothing() async throws {
        try await withTempRoot { root in
            let files = RecordingFileOperations()
            let store = LibraryStore(root: root, files: files)
            let kept = try await store.keep(processed())
            let eventsBefore = files.events

            try await store.delete(UUID())

            #expect(files.events == eventsBefore)
            #expect(try await store.stickers() == [kept])
        }
    }
}

// MARK: - Launch: missing, corrupt, re-instantiation

@Suite struct LibraryStoreLaunchTests {
    @Test func stickersSurviveReinstantiation() async throws {
        try await withTempRoot { root in
            let first: Sticker
            let second: Sticker
            do {
                let store = LibraryStore(root: root)
                first = try await store.keep(processed("one", png: Data([1, 1])))
                second = try await store.keep(processed("two", png: Data([2, 2])))
            }

            let reopened = LibraryStore(root: root)

            let stickers = try await reopened.stickers()
            #expect(stickers == [second, first])
            #expect(try Data(contentsOf: reopened.fileURL(for: first)) == Data([1, 1]))
            #expect(try Data(contentsOf: reopened.fileURL(for: second)) == Data([2, 2]))
        }
    }

    @Test func aMissingIndexIsAnEmptyLibraryAndCreatesTheDirectory() async throws {
        try await withTempRoot { root in
            #expect(!FileManager.default.fileExists(atPath: root.path))

            let store = LibraryStore(root: root)

            let stickers = try await store.stickers()
            #expect(stickers.isEmpty)
            #expect(FileManager.default.fileExists(atPath: root.path))
            #expect(try names(in: root).isEmpty)  // a missing index is not a fault: nothing set aside
        }
    }

    @Test(arguments: [
        "not json at all",
        "",
        #"{"schemaVersion": 1}"#,                                   // no stickers key
        #"{"schemaVersion": 1, "stickers": [{"id": "nope"}]}"#,     // wrong element shape
        #"{"schemaVersion": 1, "stickers": [{"id": "9F1C"#,         // truncated mid-write
    ])
    func anUndecodableIndexIsPreservedAndTheLibraryStartsEmpty(contents: String) async throws {
        try await withTempRoot { root in
            // Two real stickers' PNGs exist on disk beside the corrupt index.
            let seeding = LibraryStore(root: root)
            let a = try await seeding.keep(processed("a", png: Data([0xA])))
            let b = try await seeding.keep(processed("b", png: Data([0xB])))
            let indexURL = root.appendingPathComponent("index.json")
            let garbage = Data(contents.utf8)
            try garbage.write(to: indexURL)

            let store = LibraryStore(root: root)

            #expect(try await store.stickers().isEmpty)

            // The corrupt file is moved aside byte-for-byte, not deleted...
            let aside = try corruptFiles(in: root)
            #expect(aside.count == 1)
            #expect(try Data(contentsOf: aside[0]) == garbage)
            #expect(!FileManager.default.fileExists(atPath: indexURL.path))

            // ...and the PNGs are untouched.
            #expect(try Data(contentsOf: root.appendingPathComponent(a.fileName)) == Data([0xA]))
            #expect(try Data(contentsOf: root.appendingPathComponent(b.fileName)) == Data([0xB]))
        }
    }

    @Test func theCorruptFileIsMovedNotCopiedOrDeletedAndKeepStillWorksAfterwards() async throws {
        try await withTempRoot { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let garbage = Data("{{{".utf8)
            try garbage.write(to: root.appendingPathComponent("index.json"))
            let files = RecordingFileOperations()
            let store = LibraryStore(root: root, files: files)

            let kept = try await store.keep(processed())

            // Move, then write: the corrupt bytes are never overwritten in place.
            guard case .move(let from, let to) = files.events.first else {
                Issue.record("expected the corrupt index to be moved first, got \(files.events)")
                return
            }
            #expect(from == "index.json")
            #expect(to.hasPrefix("index.corrupt-") && to.hasSuffix(".json"))
            #expect(Array(files.events.dropFirst()) == [.write(kept.fileName), .write("index.json")])

            let aside = try corruptFiles(in: root)
            #expect(aside.count == 1)
            #expect(try Data(contentsOf: aside[0]) == garbage)
            #expect(try await LibraryStore(root: root).stickers() == [kept])
        }
    }

    @Test func aFailureToSetTheCorruptIndexAsideIsThrownNotSwallowed() async throws {
        try await withTempRoot { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let garbage = Data("{{{".utf8)
            try garbage.write(to: root.appendingPathComponent("index.json"))
            let files = RecordingFileOperations(failing: { event in
                if case .move = event { return true }
                return false
            })
            let store = LibraryStore(root: root, files: files)

            await #expect(throws: RecordingFileOperations.Injected.self) {
                try await store.keep(processed())
            }

            // Nothing was written over the corrupt index.
            #expect(try Data(contentsOf: root.appendingPathComponent("index.json")) == garbage)
            #expect(files.events.allSatisfy { if case .move = $0 { true } else { false } })
        }
    }
}

// MARK: - App Group root

@Suite struct LibraryStoreAppGroupTests {
    @Test func aNilContainerURLFailsLoudlyWithAThrownError() {
        #expect(throws: LibraryStoreError.appGroupContainerUnavailable("group.test.missing")) {
            try LibraryStore(appGroupIdentifier: "group.test.missing", containerURL: { _ in nil })
        }
    }

    @Test func theDefaultIdentifierIsTheOneInTheEntitlements() {
        #expect(LibraryStore.appGroupIdentifier == "group.com.backhaushold.openmoji")
    }

    @Test func theRootIsStickersUnderApplicationSupportInTheGroupContainer() async throws {
        try await withTempRoot { root in
            // `root` is <tmp>/<unique>/Library/Application Support/Stickers; its
            // great-grandparent plays the role of the App Group container.
            let container = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let requested = Mutex<String?>(nil)

            let store = try LibraryStore(
                appGroupIdentifier: "group.test.container",
                containerURL: { id in requested.withLock { $0 = id }; return container })
            let kept = try await store.keep(processed())

            #expect(requested.withLock { $0 } == "group.test.container")
            #expect(
                try Data(contentsOf: root.appendingPathComponent(kept.fileName))
                    == processed().png)
        }
    }
}

// MARK: - Model

@Suite struct StickerModelTests {
    @Test func theIndexRoundTripsThroughJSON() throws {
        let sticker = Sticker(
            id: UUID(), prompt: "p", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modelID: "m", quality: "medium", pixelSize: 300, byteCount: 10)
        let index = LibraryIndex(schemaVersion: 1, stickers: [sticker])

        let decoded = try LibraryIndex.makeDecoder().decode(
            LibraryIndex.self, from: LibraryIndex.makeEncoder().encode(index))

        #expect(decoded == index)
        #expect(sticker.fileName == "\(sticker.id.uuidString).png")
    }
}
