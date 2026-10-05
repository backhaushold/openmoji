import SwiftUI

/// Expanded Compose (tech spec §10; FR-6): the prompt field with its
/// 200-character limit and counter, Generate, and the gear that opens
/// Settings, and the back button to the library (ADR-0017).
///
/// The field and its counter are `PromptField`, shared with Preview. Text
/// styles only, so everything follows Dynamic Type; the scroll view keeps it
/// usable at the largest sizes and with the keyboard up.
struct ComposeView: View {
    let model: AppModel
    let onShowSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PromptField(model: model)
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
