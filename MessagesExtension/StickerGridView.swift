import SwiftUI

/// The library grid (tech spec §10, FR-17): the kept stickers, newest first,
/// in a lazy grid that fills the space it is given. Shared by the expanded
/// landing screen (`LibraryView`) and the minimal compact layout
/// (`CompactHomeView`). It reads the library when it appears; whatever changes
/// the library later calls `AppModel.reloadLibrary()`.
///
/// With no stickers it shows a bare placeholder, until the empty state
/// replaces it.
struct StickerGridView: View {
    let model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 12)]

    var body: some View {
        Group {
            if model.stickers.isEmpty {
                Text("Your stickers will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.stickers) { sticker in
                            StickerCell(sticker: sticker, url: model.fileURL(for: sticker))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
        }
        .task { await model.reloadLibrary() }
    }
}
