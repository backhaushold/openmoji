import SwiftUI

/// What the library shows when a search matches no sticker (tech spec §10):
/// the query quoted back, in place of the grid. Not the empty-library state
/// (`LibraryEmptyStateView`), which is for a library with no stickers at all;
/// clearing the search brings the stickers back.
///
/// Expanded only, since the search field is: compact never has a query. Text
/// styles only, so it follows Dynamic Type; if the content outgrows the space
/// (a long query at the largest sizes) it scrolls. The icon is decoration, so
/// VoiceOver skips it and reads the message.
struct LibraryNoMatchView: View {
    /// The trimmed query (`StickerSearch.trimmed`).
    let query: String

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Verbatim: the query is typed text, not a localisation key.
            Text(verbatim: "No stickers match \"\(query)\"")
                .font(.title3)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}
