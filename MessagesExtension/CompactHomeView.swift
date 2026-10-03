import SwiftUI

/// Compact, ready for a prompt (tech spec §10): a "New sticker" button that
/// asks for the expanded style. There is no text field here; Apple recommends
/// against text entry in compact, and the prompt is typed once expanded.
/// The library grid (FR-17) goes in the placeholder.
struct CompactHomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Text("Your stickers will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { model.startNewSticker() } label: {
                Label("New sticker", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Opens the full screen view to describe a sticker")
        }
        .padding()
    }
}
