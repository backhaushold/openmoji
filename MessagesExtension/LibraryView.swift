import SwiftUI

/// The expanded landing screen (tech spec §10, ADR-0017): the library area and
/// one action. Ready for a prompt, the action is "New sticker", which opens
/// Compose; with no key it is "Set up OpenMoji", which opens Settings. The
/// library is never gated on the key, since browsing and sending stickers need
/// none (NFR-10).
///
/// Above the grid is a search field that narrows it to the stickers whose
/// prompt contains the text (`StickerSearch`). It shows only when the library
/// has stickers. The query is view state, not saved: it starts empty each time
/// this screen appears.
struct LibraryView: View {
    let model: AppModel
    let needsSetUp: Bool
    /// Opens the Settings sheet (`RootView` owns it, as for Compose's gear).
    let onSetUp: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(spacing: 12) {
            if !model.stickers.isEmpty {
                LibrarySearchField(query: $query)
            }

            StickerGridView(model: model, needsSetUp: needsSetUp, query: query)

            Button {
                if needsSetUp { onSetUp() } else { model.startNewSticker() }
            } label: {
                Label(needsSetUp ? "Set up OpenMoji" : "New sticker", systemImage: needsSetUp ? "key" : "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint(
                needsSetUp ? "Opens settings to add your OpenAI key" : "Opens the screen to describe a sticker"
            )
        }
        .padding()
    }
}
