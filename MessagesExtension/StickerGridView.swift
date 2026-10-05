import SwiftUI

/// The library grid (tech spec §10, FR-17): the kept stickers, newest first,
/// in a lazy grid that fills the space it is given. Shared by the expanded
/// landing screen (`LibraryView`) and the minimal compact layout
/// (`CompactHomeView`). It reads the library when it appears; whatever changes
/// the library later calls `AppModel.reloadLibrary()`.
///
/// Touch-and-hold on a cell opens a context menu with Delete (FR-19).
///
/// With no stickers it shows the empty state (FR-20), which points at the
/// button the caller puts under the grid. It stays blank until the first read
/// has finished, so it doesn't flash before the stickers arrive; it goes away
/// by itself once a Keep reloads the library and `model.stickers` has an entry.
struct StickerGridView: View {
    let model: AppModel
    /// No key: the button under the grid is "Set up OpenMoji", not "New sticker".
    let needsSetUp: Bool

    /// Whether this grid's first read of the library has finished. Local, since
    /// `AppModel` has no loaded flag: it can't tell "not read yet" from "empty".
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 12)]

    var body: some View {
        Group {
            if !model.stickers.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.stickers) { sticker in
                            StickerCell(sticker: sticker, url: model.fileURL(for: sticker))
                                .aspectRatio(1, contentMode: .fit)
                                .contextMenu {
                                    // No confirmation: the spec asks for none. Hold opens the
                                    // menu and a drag still peels the sticker (OQ-10, ADR-0008).
                                    Button(role: .destructive) {
                                        Task { await model.delete(sticker) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            } else if loaded {
                LibraryEmptyStateView(needsSetUp: needsSetUp, compact: model.presentationStyle == .compact)
            } else {
                Color.clear
            }
        }
        .task {
            await model.reloadLibrary()
            loaded = true
        }
    }
}
