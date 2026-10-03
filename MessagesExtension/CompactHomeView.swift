import SwiftUI

/// Compact (tech spec §8, §10): the library area and one action. Ready for a
/// prompt, the action is "New sticker"; with no key it is "Set up OpenMoji".
/// Either button asks for the expanded style: there is no text field here
/// (Apple recommends against text entry in compact), and expanded opens the
/// prompt, or Settings when there is no key (FR-5). The library is never
/// gated on the key, since sending stickers needs none (NFR-10).
/// The library grid (FR-17) goes in the placeholder.
struct CompactHomeView: View {
    let model: AppModel
    let needsSetUp: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Your stickers will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
