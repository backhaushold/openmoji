import SwiftUI

/// The prompt field with its counter (tech spec §10; FR-6, FR-12), shared by
/// Compose and Preview. Both edit `AppModel.prompt`, so what Compose left is
/// what Preview starts from and the other way round.
///
/// The limit itself lives in `AppModel.prompt`, so the field can't go over it
/// however the text arrives (typing, paste, dictation).
///
/// The field edits a local copy of `model.prompt`. `AppModel` enforces the
/// limit, but a `TextField` bound straight to it ignores the model cutting the
/// text during the edit (a paste stays on screen in full). Writing the cut text
/// back in a later update makes the field show it.
struct PromptField: View {
    let model: AppModel

    @State private var draft: String

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.prompt)
    }

    var body: some View {
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
}
