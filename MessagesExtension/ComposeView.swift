import SwiftUI

/// Expanded Compose (tech spec §10; FR-6): the prompt field with its
/// 200-character limit and counter, Generate, and the gear that opens
/// Settings, and the back button to the library (ADR-0017).
///
/// The limit itself lives in `AppModel.prompt`, so the field can't go over it
/// however the text arrives (typing, paste, dictation). Text styles only, so
/// everything follows Dynamic Type; the scroll view keeps it usable at the
/// largest sizes and with the keyboard up.
struct ComposeView: View {
    let model: AppModel
    let onShowSettings: () -> Void

    @State private var draft: String

    init(model: AppModel, onShowSettings: @escaping () -> Void) {
        self.model = model
        self.onShowSettings = onShowSettings
        _draft = State(initialValue: model.prompt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                promptField
                generateButton
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        HStack {
            Button { model.closeCompose() } label: {
                Label("Stickers", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityHint("Goes back to your stickers")
            Text("OpenMoji")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button(action: onShowSettings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityHint("Opens the OpenAI key settings")
        }
    }

    /// The field edits a local copy of `model.prompt`. `AppModel` enforces the
    /// limit, but a `TextField` bound straight to it ignores the model cutting
    /// the text during the edit (a paste stays on screen in full). Writing the
    /// cut text back in a later update makes the field show it.
    private var promptField: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField(
                "Describe your sticker",
                text: $draft,
                prompt: Text("Describe your sticker, like \"grumpy cat\""),
                axis: .vertical
            )
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Sticker description")
            .accessibilityHint("Up to \(AppModel.promptLimit) characters")
            .onChange(of: draft) { _, typed in
                model.prompt = typed
                if model.prompt != typed { draft = model.prompt }
            }
            .onChange(of: model.prompt) { _, current in
                if draft != current { draft = current }
            }

            counter
        }
    }

    private var counter: some View {
        let atLimit = model.promptCount >= AppModel.promptLimit
        return Text("\(model.promptCount)/\(AppModel.promptLimit)")
            .font(.footnote)
            .monospacedDigit()
            .fontWeight(atLimit ? .semibold : .regular)
            .foregroundStyle(atLimit ? Color.orange : Color.secondary)
            .accessibilityLabel(
                "\(model.promptCount) of \(AppModel.promptLimit) characters"
                    + (atLimit ? ", limit reached" : "")
            )
    }

    private var generateButton: some View {
        Button { model.generate() } label: {
            Label("Generate", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canGenerate)
        .accessibilityHint("Makes a sticker from your description")
    }
}
