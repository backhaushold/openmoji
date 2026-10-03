import SwiftUI

/// The Settings sheet (tech spec §8, §10; FR-1 to FR-4): one `SecureField`,
/// Save, Clear. With a key saved the field gives way to `•••• last4`; the key
/// itself is never put back in a field.
///
/// Text styles only, so everything follows Dynamic Type.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// Closes the sheet, or leaves Settings once a key is saved.
    let onDone: () -> Void

    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                keySection
                if let message = model.statusMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(model.statusIsProblem ? Color.orange : Color.green)
                        if model.offersSaveAnyway {
                            Button("Save anyway") { model.saveAnyway() }
                                .accessibilityHint("Saves the key without checking it")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.savedKeyDisplay != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: model.statusMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    @ViewBuilder private var keySection: some View {
        Section {
            if let display = model.savedKeyDisplay, let last4 = model.savedKeyLast4 {
                LabeledContent("OpenAI key") { Text(display) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("OpenAI key saved, ending in \(last4)")
                Button("Clear key", role: .destructive) { confirmingClear = true }
                    .accessibilityHint("Removes the saved key from this device")
                    .confirmationDialog("Clear the saved key?", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear key", role: .destructive) { model.clear() }
                    } message: {
                        Text("You will need to enter a key again to make stickers.")
                    }
            } else {
                SecureField("OpenAI key", text: $model.keyInput, prompt: Text("Paste your OpenAI key"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(model.isChecking)
                    .accessibilityLabel("OpenAI key")
                    .accessibilityHint("Paste the secret key from your OpenAI account")
                if model.isChecking {
                    ProgressView("Checking the key…")
                } else {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                        .accessibilityHint("Checks the key with OpenAI, then saves it on this device")
                }
            }
        } footer: {
            Text("The key stays in this device's Keychain and is only sent to OpenAI.")
        }
    }
}
