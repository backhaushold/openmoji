import SwiftUI

/// Compact (tech spec §8, §10): the library area and one action. Ready for a
/// prompt, the action is "New sticker"; with no key it is "Set up OpenMoji".
/// Either button asks for the expanded style: there is no text field here
/// (Apple recommends against text entry in compact). "New sticker" then lands
/// on Compose; with no key, expanded lands on the library, whose "Set up
/// OpenMoji" opens Settings (FR-5, ADR-0017). The library is never gated on
/// the key, since sending stickers needs none (NFR-10).
struct CompactHomeView: View {
    let model: AppModel
    let needsSetUp: Bool

    var body: some View {
        VStack(spacing: 12) {
            StickerGridView(model: model)

            if needsSetUp {
                Button { model.startSetUp() } label: {
                    Label("Set up OpenMoji", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens the full screen view to add your OpenAI key")
            } else {
                Button { model.startNewSticker() } label: {
                    Label("New sticker", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens the full screen view to describe a sticker")
            }
        }
        .padding()
    }
}
