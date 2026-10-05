import Foundation
import OpenMojiCore
import Testing

// `SettingsModel`: entry, validate-then-save per tech spec §5.4, last-4
// display and Clear (§8, FR-1, 3, 4), with a fake validator and an in-memory
// store.

/// A fake key shaped like the real thing (it needs the `sk-` prefix) but built
/// at runtime, so no key-shaped literal is committed. Its last four characters
/// are `9876`.
private let fakeKey = ["sk", "unit", "test", "fake", "key", "9876"].joined(separator: "-")
private let fakeKeyLast4 = "9876"

/// A `KeyValidating` that answers with a canned result, records every key it
/// is asked about, and can be held mid-flight.
private actor FakeValidator: KeyValidating {
    private(set) var keys: [String] = []
    private var result: KeyValidationResult
    private var held = false
    private var gates: [CheckedContinuation<Void, Never>] = []

    init(result: KeyValidationResult = .valid) {
        self.result = result
    }

    func hold() { held = true }

    func release() {
        held = false
        for gate in gates {
            gate.resume()
        }
        gates = []
    }

    func validate(key: String) async -> KeyValidationResult {
        keys.append(key)
        if held {
            await withCheckedContinuation { gates.append($0) }
        }
        return result
    }
}

/// A Keychain that reads fine but refuses writes and deletes.
private struct FailingWritesCredentialStore: CredentialStore {
    func load() throws -> String? { nil }
    func save(_ key: String) throws { throw CredentialStoreError.keychain(-34018) }
    func clear() throws { throw CredentialStoreError.keychain(-34018) }
}

private struct Rig {
    let model: SettingsModel
    let credentials: InMemoryCredentialStore
    let validator: FakeValidator
    let app: AppModel
}

/// An `AppModel` and a `SettingsModel` wired the way `MessagesViewController`
/// wires them: clearing the key refreshes the app model.
@MainActor
private func makeRig(
    stored: String? = nil,
    result: KeyValidationResult = .valid
) -> Rig {
    let credentials = InMemoryCredentialStore(key: stored)
    let validator = FakeValidator(result: result)
    let app = AppModel(credentials: credentials, generator: FakeGenerator(), library: FakeLibrary())
    let model = SettingsModel(
        credentials: credentials,
        validator: validator,
        onCleared: { app.refreshKey() }
    )
    return Rig(model: model, credentials: credentials, validator: validator, app: app)
}

/// Every string the model publishes, for the no-key-leak checks.
@MainActor
private func publishedStrings(of model: SettingsModel) -> [String] {
    [
        String(describing: model.status),
        model.statusMessage ?? "",
        model.savedKeyDisplay ?? "",
        model.savedKeyLast4 ?? "",
    ]
}

/// Entry: trim, the `sk-` prefix, and what gets sent (FR-1).
@MainActor
struct SettingsModelEntryTests {
    @Test(arguments: ["", "   ", "not-a-key", "SK-upper", "sk", "xsk-abc", "Bearer sk-abc"])
    func inputWithoutTheSkPrefixIsRejectedWithNoNetworkCall(input: String) async {
        let rig = makeRig()
        rig.model.keyInput = input
        await rig.model.save()

        #expect(await rig.validator.keys.isEmpty)
        #expect(try! rig.credentials.load() == nil)
        if input.trimmingCharacters(in: .whitespaces).isEmpty {
            // Blank input can't even be submitted.
            #expect(rig.model.canSave == false)
            #expect(rig.model.status == .idle)
        } else {
            #expect(rig.model.status == .notAKey)
            #expect(rig.model.statusMessage == "That doesn't look like an OpenAI key")
        }
    }

    @Test func theInputIsTrimmedBeforeValidatingAndSaving() async throws {
        let rig = makeRig()
        rig.model.keyInput = "  \n\(fakeKey)\t "
        await rig.model.save()

        #expect(await rig.validator.keys == [fakeKey])
        #expect(try rig.credentials.load() == fakeKey)
    }

    @Test func savingWhileACheckIsInFlightIsIgnored() async throws {
        let rig = makeRig()
        await rig.validator.hold()
        rig.model.keyInput = fakeKey

        let first = Task { await rig.model.save() }
        // Let the first save reach the validator.
        while await rig.validator.keys.isEmpty {
            await Task.yield()
        }
        #expect(rig.model.status == .checking)
        #expect(rig.model.isChecking)
        #expect(rig.model.canSave == false)

        await rig.model.save()
        await rig.validator.release()
        await first.value

        #expect(await rig.validator.keys == [fakeKey])
        #expect(rig.model.status == .saved)
    }

    @Test func editingTheInputDropsTheMessage() async {
        let rig = makeRig(result: .invalid)
        rig.model.keyInput = fakeKey
        await rig.model.save()
        #expect(rig.model.status == .invalid)

        rig.model.keyInput = fakeKey + "x"
        #expect(rig.model.status == .idle)
        #expect(rig.model.statusMessage == nil)
    }
}

/// Every §5.4 outcome: its message, and whether the key is saved.
@MainActor
struct SettingsModelValidationTests {
    @Test func a200SavesTheKey() async throws {
        let rig = makeRig(result: .valid)
        rig.model.keyInput = fakeKey
        await rig.model.save()

        #expect(rig.model.status == .saved)
        #expect(rig.model.statusMessage == "Key saved.")
        #expect(rig.model.statusIsProblem == false)
        #expect(try rig.credentials.load() == fakeKey)
    }

    @Test func a401ShowsItsMessageAndDoesNotSave() async throws {
        let rig = makeRig(result: .invalid)
        rig.model.keyInput = fakeKey
        await rig.model.save()

        #expect(rig.model.status == .invalid)
        #expect(rig.model.statusMessage == "That key isn't valid.")
        #expect(rig.model.statusIsProblem)
        #expect(rig.model.offersSaveAnyway == false)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func a403ShowsItsMessageAndDoesNotSave() async throws {
        let rig = makeRig(result: .notPermitted)
        rig.model.keyInput = fakeKey
        await rig.model.save()

        #expect(rig.model.status == .notPermitted)
        #expect(rig.model.statusMessage == "That key doesn't have permission. Check its permissions in OpenAI.")
        #expect(rig.model.statusIsProblem)
        #expect(rig.model.offersSaveAnyway == false)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func a404SavesTheKeyWithAWarning() async throws {
        let rig = makeRig(result: .modelNotVisible)
        rig.model.keyInput = fakeKey
        await rig.model.save()

        #expect(rig.model.status == .savedModelNotVisible)
        #expect(rig.model.statusMessage == "Key saved, but this account can't use the image model yet.")
        #expect(rig.model.statusIsProblem)
        #expect(try rig.credentials.load() == fakeKey)
        #expect(rig.model.savedKeyDisplay == "•••• \(fakeKeyLast4)")
    }

    @Test func offlineOffersSaveAnywayAndDoesNotSaveYet() async throws {
        let rig = makeRig(result: .couldNotCheck)
        rig.model.keyInput = fakeKey
        await rig.model.save()

        #expect(rig.model.status == .couldNotCheck)
        #expect(rig.model.statusMessage == "Couldn't check that key. Check your connection, or save it anyway.")
        #expect(rig.model.offersSaveAnyway)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func saveAnywaySavesTheKeyThatCouldNotBeChecked() async throws {
        let rig = makeRig(result: .couldNotCheck)
        rig.model.keyInput = fakeKey
        await rig.model.save()
        rig.model.saveAnyway()

        #expect(rig.model.status == .savedUnchecked)
        #expect(rig.model.statusMessage == "Key saved without checking.")
        #expect(rig.model.offersSaveAnyway == false)
        #expect(try rig.credentials.load() == fakeKey)
        #expect(rig.model.savedKeyDisplay == "•••• \(fakeKeyLast4)")
        #expect(await rig.validator.keys == [fakeKey])
    }

    @Test func saveAnywayDoesNothingUnlessACheckCouldNotBeMade() async throws {
        let rig = makeRig(result: .invalid)
        rig.model.keyInput = fakeKey
        rig.model.saveAnyway()
        #expect(try rig.credentials.load() == nil)

        await rig.model.save()
        rig.model.saveAnyway()
        #expect(rig.model.status == .invalid)
        #expect(try rig.credentials.load() == nil)
    }

    @Test func editingTheKeyWithdrawsSaveAnyway() async throws {
        let rig = makeRig(result: .couldNotCheck)
        rig.model.keyInput = fakeKey
        await rig.model.save()
        #expect(rig.model.offersSaveAnyway)

        rig.model.keyInput = "something else"
        #expect(rig.model.offersSaveAnyway == false)
        rig.model.saveAnyway()
        #expect(try rig.credentials.load() == nil)
    }

    @Test func aFailedKeychainWriteSaysSoAndKeepsTheInput() async {
        let model = SettingsModel(credentials: FailingWritesCredentialStore(), validator: FakeValidator())
        model.keyInput = fakeKey
        await model.save()

        #expect(model.status == .saveFailed)
        #expect(model.statusMessage == "Couldn't save the key. Try again.")
        #expect(model.savedKeyDisplay == nil)
        #expect(model.keyInput == fakeKey)
    }
}

/// After a save the key shows only as `•••• last4`, read back from the store
/// (FR-3, NFR-6).
@MainActor
struct SettingsModelDisplayTests {
    @Test func noKeyShowsNoDisplay() {
        let model = makeRig().model
        #expect(model.savedKeyDisplay == nil)
        #expect(model.savedKeyLast4 == nil)
    }

    @Test func aStoredKeyShowsAsBulletsAndTheLastFour() {
        let model = makeRig(stored: fakeKey).model
        #expect(model.savedKeyLast4 == fakeKeyLast4)
        #expect(model.savedKeyDisplay == "•••• 9876")
    }

    @Test func afterASaveTheFieldIsEmptyAndOnlyTheLastFourShow() async {
        let rig = makeRig()
        rig.model.keyInput = fakeKey
        await rig.model.save()

        #expect(rig.model.keyInput.isEmpty)
        #expect(rig.model.savedKeyDisplay == "•••• 9876")
        for text in publishedStrings(of: rig.model) {
            #expect(!text.contains(fakeKey))
            #expect(!text.contains("sk-"))
        }
    }

    @Test(arguments: [
        KeyValidationResult.valid, .modelNotVisible, .invalid, .notPermitted, .couldNotCheck,
    ])
    func noOutcomePutsTheKeyInPublishedState(result: KeyValidationResult) async {
        let rig = makeRig(result: result)
        rig.model.keyInput = fakeKey
        await rig.model.save()
        rig.model.saveAnyway()

        for text in publishedStrings(of: rig.model) {
            #expect(!text.contains(fakeKey))
        }
        // Only the last four of a stored key are ever surfaced.
        if let display = rig.model.savedKeyDisplay {
            #expect(display == "•••• 9876")
            #expect(rig.model.keyInput.isEmpty)
        }
    }

    @Test func refreshingReadsTheStoreAgain() throws {
        let rig = makeRig(stored: fakeKey)
        try rig.credentials.save("sk-" + "other-key-5432")
        #expect(rig.model.savedKeyLast4 == fakeKeyLast4)

        rig.model.refresh()
        #expect(rig.model.savedKeyLast4 == "5432")
    }

    @Test func anUnreadableKeychainShowsNoDisplay() {
        let model = SettingsModel(credentials: UnreadableCredentialStore(), validator: FakeValidator())
        #expect(model.savedKeyDisplay == nil)
    }
}

/// Clear removes the key and returns the app to needs-key (FR-5).
@MainActor
struct SettingsModelClearTests {
    @Test func clearRemovesTheKeyAndRoutesTheAppToNeedsKey() throws {
        let rig = makeRig(stored: fakeKey)
        #expect(rig.app.state == .idle)

        rig.model.clear()

        #expect(try rig.credentials.load() == nil)
        #expect(rig.model.savedKeyDisplay == nil)
        #expect(rig.model.savedKeyLast4 == nil)
        #expect(rig.model.status == .idle)
        #expect(rig.app.state == .needsKey)
    }

    @Test func clearAfterASaveInThisSheetAlsoWorks() async throws {
        let rig = makeRig()
        rig.model.keyInput = fakeKey
        await rig.model.save()
        rig.app.refreshKey()
        #expect(rig.app.state == .idle)

        rig.model.clear()

        #expect(try rig.credentials.load() == nil)
        #expect(rig.app.state == .needsKey)
    }

    @Test func aFailedClearSaysSoAndDoesNotRoute() {
        var cleared = false
        let model = SettingsModel(
            credentials: FailingWritesCredentialStore(),
            validator: FakeValidator(),
            onCleared: { cleared = true }
        )
        model.clear()

        #expect(model.status == .clearFailed)
        #expect(model.statusMessage == "Couldn't clear the key. Try again.")
        #expect(cleared == false)
    }
}
