import Foundation
import Messages
import OpenMojiCore
import Testing
import UIKit

// The library grid's state in `AppModel` (tech spec §10, FR-17, NFR-10):
// reading the library newest first, reloading after a change (what Keep and
// Delete will call), and building each cell's `MSSticker`.

@MainActor
private func makeModel(library: any StickerLibrary) -> AppModel {
    AppModel(credentials: InMemoryCredentialStore(key: "test-fake-key-0000"), generator: FakeGenerator(), library: library)
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenMojiLibraryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
struct LibraryReloadTests {
    @Test func theLibraryIsEmptyUntilItIsRead() async {
        let model = makeModel(library: FakeLibrary(stickers: [makeSticker()]))
        #expect(model.stickers.isEmpty)
        await model.reloadLibrary()
        #expect(model.stickers.count == 1)
    }

    @Test func reloadingShowsTheLibraryInTheOrderTheStoreGives() async {
        let newer = makeSticker(prompt: "newer", createdAt: Date(timeIntervalSince1970: 2_000_000))
        let older = makeSticker(prompt: "older", createdAt: Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(library: FakeLibrary(stickers: [newer, older]))
        await model.reloadLibrary()
        #expect(model.stickers == [newer, older])
    }

    @Test func reloadingPicksUpAChangeMadeAfterTheFirstRead() async {
        let first = makeSticker(prompt: "first")
        let library = FakeLibrary(stickers: [first])
        let model = makeModel(library: library)
        await model.reloadLibrary()

        let second = makeSticker(prompt: "second")
        await library.set([second, first])
        await model.reloadLibrary()
        #expect(model.stickers == [second, first])

        await library.set([second])
        await model.reloadLibrary()
        #expect(model.stickers == [second])
    }

    @Test func aFailedReadKeepsWhatWasShown() async {
        let library = FakeLibrary(stickers: [makeSticker()])
        let model = makeModel(library: library)
        await model.reloadLibrary()

        await library.set([])
        await library.failReads(true)
        await model.reloadLibrary()
        #expect(model.stickers.count == 1)
        #expect(await library.readCount == 2)
    }

    @Test func anOlderReadFinishingLateDoesNotOverwriteANewerOne() async {
        let old = makeSticker(prompt: "old")
        let new = makeSticker(prompt: "new")
        let library = FakeLibrary(stickers: [old])
        let model = makeModel(library: library)

        // The first read starts, and is held, with only `old` in the library.
        await library.hold()
        let slow = Task { await model.reloadLibrary() }
        while await library.readCount < 1 { await Task.yield() }

        // `new` is kept, and a second read sees it.
        await library.set([new, old])
        await library.release()
        await model.reloadLibrary()
        #expect(model.stickers == [new, old])

        await slow.value
        #expect(model.stickers == [new, old])
    }

    @Test func theFileURLComesFromTheLibrary() {
        let sticker = makeSticker()
        let library = FakeLibrary()
        let model = makeModel(library: library)
        #expect(model.fileURL(for: sticker) == library.fileURL(for: sticker))
        #expect(model.fileURL(for: sticker).lastPathComponent == "\(sticker.id.uuidString).png")
    }

    @Test func reloadingDoesNotChangeTheRoute() async {
        let model = makeModel(library: FakeLibrary(stickers: [makeSticker()]))
        model.presentationStyle = .expanded
        #expect(model.route == .library)
        await model.reloadLibrary()
        #expect(model.route == .library)
        #expect(model.state == .idle)
    }
}

/// The real `LibraryStore` behind the seam: what Keep writes, the grid reads,
/// newest first, from files `MSSticker` can load in place.
@MainActor
struct LibraryStoreWiringTests {
    @Test func aStickerKeptAfterTheFirstReadShowsOnTheNextReloadAtTheFront() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(root: directory)
        let model = makeModel(library: store)

        await model.reloadLibrary()
        #expect(model.stickers.isEmpty)

        let first = try await store.keep(makeProcessedSticker(prompt: "first"), at: Date(timeIntervalSince1970: 1_000_000))
        let second = try await store.keep(makeProcessedSticker(prompt: "second"), at: Date(timeIntervalSince1970: 2_000_000))
        await model.reloadLibrary()

        #expect(model.stickers == [second, first])
        #expect(model.fileURL(for: second) == store.fileURL(for: second))
        #expect(FileManager.default.fileExists(atPath: model.fileURL(for: second).path))
    }

    @Test func keepingThroughTheModelWritesTheStoreAndShowsTheStickerFirst() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(root: directory)
        let generator = FakeGenerator()
        let model = AppModel(
            credentials: InMemoryCredentialStore(key: "test-fake-key-0000"),
            generator: generator,
            library: store
        )
        model.presentationStyle = .expanded

        for prompt in ["first", "second"] {
            model.prompt = prompt
            await generator.enqueue(.success(makeProcessedSticker(prompt: prompt)), for: prompt)
            model.startNewSticker()
            model.generate()
            if case .generating(let task) = model.state { await task.value }
            #expect(model.route == .preview)

            await model.keep()
            #expect(model.route == .library)
        }

        #expect(model.stickers.map(\.prompt) == ["second", "first"])
        #expect(try await store.stickers() == model.stickers)
        for sticker in model.stickers {
            let png = try Data(contentsOf: model.fileURL(for: sticker))
            #expect(png == makeProcessedSticker().png)
        }
    }
}

/// `MSSticker.libraryEntry`: the sticker behind each cell. VoiceOver reads its
/// description, the prompt cut to 150 Unicode scalars (FR-15, NFR-9).
@MainActor
struct LibraryEntryStickerTests {
    private func writePNG(to url: URL, edge: CGFloat = 300) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge)).image { context in
            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        try #require(image.pngData()).write(to: url)
    }

    @Test func loadsFromTheFileInPlaceWithThePromptAsItsDescription() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sticker = makeSticker(prompt: "a happy cat")
        let url = directory.appendingPathComponent(sticker.fileName)
        try writePNG(to: url)

        let loaded = try #require(MSSticker.libraryEntry(sticker, at: url))
        #expect(loaded.localizedDescription == "a happy cat")
        #expect(loaded.imageFileURL == url)
    }

    @Test func aLongPromptIsCutToThe150ScalarLimit() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sticker = makeSticker(prompt: String(repeating: "x", count: 200))
        let url = directory.appendingPathComponent(sticker.fileName)
        try writePNG(to: url)

        let loaded = try #require(MSSticker.libraryEntry(sticker, at: url))
        #expect(loaded.localizedDescription == sticker.accessibilityText)
        #expect(loaded.localizedDescription.unicodeScalars.count == 150)
    }
}
