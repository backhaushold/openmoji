import Foundation
import OpenMojiCore
import Testing

// The audit log of prompts through `AppModel` (ADR-0020, openmoji-6dr.4).

private struct Rig {
    let model: AppModel
    let generator: FakeGenerator
    let log: FakePromptLog
}

@MainActor
private func makeRig(prompt: String = defaultTestPrompt, log: FakePromptLog = FakePromptLog()) -> Rig {
    let generator = FakeGenerator()
    let model = AppModel(
        credentials: InMemoryCredentialStore(key: "test-fake-key-0000"),
        generator: generator,
        library: FakeLibrary(),
        promptLog: log
    )
    model.prompt = prompt
    return Rig(model: model, generator: generator, log: log)
}

/// Waits for the in-flight generation, if any, to finish and be applied.
@MainActor
private func settle(_ model: AppModel) async {
    if case .generating(let task) = model.state { await task.value }
}

@MainActor
struct AuditLogModelTests {
    @Test func thePromptIsOnRecordWhileTheGenerationIsStillRunning() async {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()

        while await rig.generator.prompts.isEmpty { await Task.yield() }
        #expect(await rig.log.prompts == [defaultTestPrompt])

        await rig.generator.release()
        await settle(rig.model)
    }

    @Test func aRegenerateRecordsThePromptAsEdited() async {
        let rig = makeRig(prompt: "a cat")
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a cat")), for: "a cat")
        await rig.generator.enqueue(.success(makeProcessedSticker(prompt: "a cat in a hat")), for: "a cat in a hat")
        rig.model.generate()
        await settle(rig.model)

        rig.model.prompt = "a cat in a hat"
        rig.model.generate()
        await settle(rig.model)

        #expect(await rig.log.prompts == ["a cat", "a cat in a hat"])
    }

    @Test func aDiscardedStickerLeavesItsPromptOnRecord() async {
        let rig = makeRig()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)

        rig.model.dismissPreview()

        #expect(await rig.log.prompts == [defaultTestPrompt])
    }

    @Test func aRefusedPromptIsRecorded() async {
        let rig = makeRig()
        await rig.generator.enqueue(.failure(.contentRefused))
        rig.model.generate()
        await settle(rig.model)

        #expect(rig.model.state == .failed(.contentRefused, prompt: defaultTestPrompt))
        #expect(await rig.log.prompts == [defaultTestPrompt])
    }

    @Test func aCancelledGenerationIsRecorded() async throws {
        let rig = makeRig()
        await rig.generator.hold()
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        guard case .generating(let task) = rig.model.state else {
            Issue.record("not generating")
            return
        }

        rig.model.cancel()
        await rig.generator.release()
        await task.value

        #expect(await rig.log.prompts == [defaultTestPrompt])
    }

    @Test func aBlankPromptRecordsNothing() async {
        let rig = makeRig(prompt: "   ")
        rig.model.generate()
        await settle(rig.model)

        #expect(await rig.log.prompts.isEmpty)
    }

    @Test func aLogThatCannotBeWrittenDoesNotStopTheGeneration() async {
        let rig = makeRig()
        await rig.log.failWrites(true)
        await rig.generator.enqueue(.success(makeProcessedSticker()))
        rig.model.generate()
        await settle(rig.model)

        #expect(rig.model.state == .preview(makeProcessedSticker()))
    }

    @Test func theAuditLogReadsNewestFirst() async throws {
        let older = PromptLogEntry(at: Date(timeIntervalSince1970: 1_000_000), prompt: "a cat")
        let newer = PromptLogEntry(at: Date(timeIntervalSince1970: 1_000_060), prompt: "a dog")
        let rig = makeRig(log: FakePromptLog(entries: [older, newer]))

        try await #expect(rig.model.auditLog() == [newer, older])
    }

    @Test func anAuditLogThatCannotBeReadThrows() async {
        let rig = makeRig()
        await rig.log.failReads(true)

        await #expect(throws: FakePromptLog.ReadFailure.self) {
            try await rig.model.auditLog()
        }
    }
}
