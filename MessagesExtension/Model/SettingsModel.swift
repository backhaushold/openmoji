import Foundation
import Observation
import OpenMojiCore

/// The Settings sheet's state and logic (tech spec §5.4, §8; FR-1, 3, 4).
///
/// Entry trims the input and requires an `sk-` prefix before any network call.
/// Then validate, then save: 200 and 404 save (404 with a warning), 401 and 403
/// don't, and "couldn't check" waits for an explicit Save anyway.
///
/// The key is only ever in `keyInput` while the user is typing it and in the
/// Keychain. After a save the input is emptied and the saved key shows as its
/// last four characters, read back with `load()`; the full key is never put
/// back in a field or kept in published state, a message or an error (NFR-6).
@MainActor
@Observable
final class SettingsModel {
    /// What the sheet says about the last action. A closed set with no
    /// payloads, so nothing here can hold the key.
    enum Status: Equatable {
        case idle
        case checking
        /// Failed the trim-and-`sk-` check; nothing was sent anywhere.
        case notAKey
        case invalid
        case notPermitted
        /// Offline, timed out or no verdict: Save anyway is offered.
        case couldNotCheck
        case saved
        /// 404: saved, with a warning.
        case savedModelNotVisible
        /// Saved through Save anyway, without a verdict.
        case savedUnchecked
        case saveFailed
        case clearFailed
    }

    /// The text field's contents. Emptied after a save or a clear; editing it
    /// drops a stale message and any pending Save anyway.
    var keyInput = "" {
        didSet {
            guard keyInput != oldValue else { return }
            uncheckedKey = nil
            if status != .checking { status = .idle }
        }
    }

    private(set) var status = Status.idle

    /// The last four characters of the stored key, as of the last `load()`.
    /// Never more than that.
    private(set) var savedKeyLast4: String?

    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let validator: any KeyValidating
    @ObservationIgnored private let onCleared: @MainActor () -> Void
    /// The candidate that couldn't be checked, held for Save anyway.
    @ObservationIgnored private var uncheckedKey: String?

    /// `onCleared` runs after the key is removed, so the host can route to the
    /// needs-key state (FR-5).
    init(
        credentials: any CredentialStore,
        validator: any KeyValidating,
        onCleared: @escaping @MainActor () -> Void = {}
    ) {
        self.credentials = credentials
        self.validator = validator
        self.onCleared = onCleared
        refresh()
    }

    /// `•••• ` and the last four characters of the stored key, or `nil` when
    /// there is none (FR-3).
    var savedKeyDisplay: String? {
        savedKeyLast4.map { "•••• " + $0 }
    }

    /// Whether the Save button can act.
    var canSave: Bool {
        status != .checking && !trimmedInput.isEmpty
    }

    var isChecking: Bool { status == .checking }

    var offersSaveAnyway: Bool { status == .couldNotCheck && uncheckedKey != nil }

    /// What to show for `status`, if anything.
    var statusMessage: String? {
        switch status {
        case .idle, .checking: nil
        case .notAKey: "That doesn't look like an OpenAI key"
        case .invalid: "That key isn't valid."
        case .notPermitted: "That key doesn't have permission. Check its permissions in OpenAI."
        case .couldNotCheck: "Couldn't check that key. Check your connection, or save it anyway."
        case .saved: "Key saved."
        case .savedModelNotVisible: "Key saved, but this account can't use the image model yet."
        case .savedUnchecked: "Key saved without checking."
        case .saveFailed: "Couldn't save the key. Try again."
        case .clearFailed: "Couldn't clear the key. Try again."
        }
    }

    /// Whether `statusMessage` is a warning or an error rather than good news.
    var statusIsProblem: Bool {
        switch status {
        case .idle, .checking, .saved, .savedUnchecked: false
        case .notAKey, .invalid, .notPermitted, .couldNotCheck, .savedModelNotVisible,
             .saveFailed, .clearFailed: true
        }
    }

    /// Re-reads the stored key's last four characters. Call when the sheet
    /// appears so the display always comes from the Keychain.
    func refresh() {
        let key = try? credentials.load()
        savedKeyLast4 = key.map { String($0.suffix(4)) }
    }

    /// Validates the input, then saves it per §5.4.
    func save() async {
        guard canSave else { return }
        let candidate = trimmedInput
        guard candidate.hasPrefix("sk-") else {
            status = .notAKey
            return
        }

        status = .checking
        uncheckedKey = nil
        let result = await validator.validate(key: candidate)
        switch result {
        case .valid:
            store(candidate, success: .saved)
        case .modelNotVisible:
            store(candidate, success: .savedModelNotVisible)
        case .invalid:
            status = .invalid
        case .notPermitted:
            status = .notPermitted
        case .couldNotCheck:
            uncheckedKey = candidate
            status = .couldNotCheck
        }
    }

    /// Saves the candidate that couldn't be checked. Does nothing otherwise.
    func saveAnyway() {
        guard let candidate = uncheckedKey, status == .couldNotCheck else { return }
        store(candidate, success: .savedUnchecked)
    }

    /// Removes the stored key and tells the host.
    func clear() {
        do {
            try credentials.clear()
        } catch {
            status = .clearFailed
            return
        }
        keyInput = ""
        uncheckedKey = nil
        status = .idle
        refresh()
        onCleared()
    }

    private var trimmedInput: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func store(_ key: String, success: Status) {
        do {
            try credentials.save(key)
        } catch {
            status = .saveFailed
            return
        }
        keyInput = ""
        uncheckedKey = nil
        status = success
        refresh()
    }
}
