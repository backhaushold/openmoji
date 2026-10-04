import SwiftUI

/// The expanded landing screen (tech spec §10, ADR-0017): the library area and
/// one action. Ready for a prompt, the action is "New sticker", which opens
/// Compose; with no key it is "Set up OpenMoji", which opens Settings. The
/// library is never gated on the key, since browsing and sending stickers need
/// none (NFR-10).
/// The library grid (FR-17) goes in the placeholder.
struct LibraryView: View {
    let model: AppModel
    let needsSetUp: Bool
    /// Opens the Settings sheet (`RootView` owns it, as for Compose's gear).
    let onSetUp: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Your stickers will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if needsSetUp {
                Button(action: onSetUp) {
                    Label("Set up OpenMoji", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens settings to add your OpenAI key")
            } else {
                Button { model.startNewSticker() } label: {
                    Label("New sticker", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens the screen to describe a sticker")
            }
        }
        .padding()
    }
}
