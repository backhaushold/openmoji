import Foundation
import Testing
@testable import OpenMojiCore

/// A unique, not-yet-created directory under the system temp dir, removed
/// when `body` returns. The log must create it (and parents) itself.
private func withTempRoot(_ body: (URL) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("PromptLogTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try await body(base.appendingPathComponent("Library/Application Support/PromptLog", isDirectory: true))
}

private let logFileName = "prompts.jsonl"

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

/// The audit log of generation prompts (ADR-0020).
struct PromptLogTests {
    @Test func aLogWithNoFileIsEmpty() async throws {
        try await withTempRoot { root in
            try await #expect(PromptLog(root: root).entries().isEmpty)
        }
    }

    @Test func recordsAreReadBackOldestFirstWithTheirDates() async throws {
        try await withTempRoot { root in
            let log = PromptLog(root: root)
            try await log.record("a cat", at: date(1_000_000))
            try await log.record("a dog", at: date(1_000_060))

            try await #expect(log.entries() == [
                PromptLogEntry(at: date(1_000_000), prompt: "a cat"),
                PromptLogEntry(at: date(1_000_060), prompt: "a dog"),
            ])
        }
    }

    @Test func theSamePromptTwiceIsTwoEntries() async throws {
        try await withTempRoot { root in
            let log = PromptLog(root: root)
            try await log.record("a cat", at: date(1_000_000))
            try await log.record("a cat", at: date(1_000_001))

            try await #expect(log.entries().count == 2)
        }
    }

    @Test func entriesSurviveANewLogOnTheSameDirectory() async throws {
        try await withTempRoot { root in
            try await PromptLog(root: root).record("a cat", at: date(1_000_000))
            let reopened = PromptLog(root: root)
            try await reopened.record("a dog", at: date(1_000_060))

            try await #expect(reopened.entries().map(\.prompt) == ["a cat", "a dog"])
        }
    }

    /// Append-only: a new record leaves the bytes already in the file as they were.
    @Test func recordingOnlyAddsToTheEndOfTheFile() async throws {
        try await withTempRoot { root in
            let log = PromptLog(root: root)
            let file = root.appendingPathComponent(logFileName)
            try await log.record("a cat", at: date(1_000_000))
            let before = try Data(contentsOf: file)

            try await log.record("a dog", at: date(1_000_060))

            let after = try Data(contentsOf: file)
            #expect(after.count > before.count)
            #expect(after.prefix(before.count) == before)
        }
    }

    @Test func aPromptWithNewlinesAndQuotesStaysOneEntry() async throws {
        try await withTempRoot { root in
            let log = PromptLog(root: root)
            let prompt = "a \"happy\" cat\nwith a hat\r\n🙂"
            try await log.record(prompt, at: date(1_000_000))
            try await log.record("a dog", at: date(1_000_060))

            try await #expect(log.entries().map(\.prompt) == [prompt, "a dog"])
        }
    }

    @Test func aLineThatDoesNotDecodeIsSkipped() async throws {
        try await withTempRoot { root in
            let log = PromptLog(root: root)
            try await log.record("a cat", at: date(1_000_000))
            let file = root.appendingPathComponent(logFileName)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"at\":\"2026-10-13T0\n".utf8))
            try handle.close()
            try await log.record("a dog", at: date(1_000_060))

            try await #expect(log.entries().map(\.prompt) == ["a cat", "a dog"])
        }
    }

    @Test func aMissingAppGroupContainerThrows() {
        #expect(throws: LibraryStoreError.appGroupContainerUnavailable("group.test.missing")) {
            try PromptLog(appGroupIdentifier: "group.test.missing", containerURL: { _ in nil })
        }
    }

    @Test func theAppGroupLogLivesUnderApplicationSupport() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let log = try PromptLog(appGroupIdentifier: "group.test.container", containerURL: { _ in container })

        try await log.record("a cat", at: date(1_000_000))

        let file = container.appendingPathComponent("Library/Application Support/PromptLog/\(logFileName)")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
