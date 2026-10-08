import OpenMojiCore
import SwiftUI

/// The library grid (tech spec §10, FR-17): the kept stickers, newest first,
/// in a lazy grid that fills the space it is given. Shared by the expanded
/// landing screen (`LibraryView`) and the minimal compact layout
/// (`CompactHomeView`). It reads the library when it appears; whatever changes
/// the library later calls `AppModel.reloadLibrary()`.
///
/// Touch-and-hold on a cell opens a context menu with Reuse prompt (FR-21),
/// which opens Compose with the sticker's prompt in the field, and Delete
/// (FR-19), and shows the sticker's whole prompt above it, since the cell has
/// no room for it. With no key the menu has Delete only.
///
/// With no stickers it shows the empty state (FR-20), which points at the
/// button the caller puts under the grid, once a read has succeeded; if the
/// read failed it shows a short error with Try again instead, so an unreadable
/// library isn't taken for an empty one. It stays blank until the first read
/// has finished (`AppModel.libraryLoad`), so it doesn't flash before the
/// stickers arrive; it goes away by itself once a Keep reloads the library and
/// `model.stickers` has an entry. Stickers already shown stay shown if a later
/// read fails.
///
/// A non-empty `query` narrows the grid to the stickers whose prompt contains
/// it (`StickerSearch`); if none does, it shows the no-match message, not the
/// empty state, which is for a library with no stickers. The cells, their menu
/// and the peel work the same on the narrowed grid, as they key off the sticker.
struct StickerGridView: View {
    let model: AppModel
    /// No key: the button under the grid is "Set up OpenMoji", not "New sticker".
    let needsSetUp: Bool
    /// What the library search field holds; empty shows every sticker.
    var query = ""

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 12)]

    private var compact: Bool { model.presentationStyle == .compact }

    /// The stickers the query leaves, newest first.
    private var shown: [Sticker] { StickerSearch.filter(model.stickers, query: query) }

    var body: some View {
        Group {
            if !model.stickers.isEmpty && shown.isEmpty {
                LibraryNoMatchView(query: StickerSearch.trimmed(query))
            } else if !model.stickers.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(shown) { sticker in
                            StickerCell(sticker: sticker, url: model.fileURL(for: sticker))
                                .aspectRatio(1, contentMode: .fit)
                                .contextMenu {
                                    // With no key there is no Compose to open, so no Reuse
                                    // prompt, as "Set up OpenMoji" replaces "New sticker" (NFR-10).
                                    if !needsSetUp {
                                        Button { model.reusePrompt(of: sticker) } label: {
                                            Label("Reuse prompt", systemImage: "square.and.pencil")
                                        }
                                    }
                                    // No confirmation: the spec asks for none. Hold opens the
                                    // menu and a drag still peels the sticker (OQ-10, ADR-0008).
                                    Button(role: .destructive) {
                                        Task { await model.delete(sticker) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                } preview: {
                                    // The prompt in full (up to 200 characters, FR-6; the
                                    // 150-scalar cut is only for VoiceOver), above the sticker.
                                    // Text styles only, so it follows Dynamic Type.
                                    VStack(spacing: 12) {
                                        Text(sticker.prompt).multilineTextAlignment(.center)
                                        StickerCell(sticker: sticker, url: model.fileURL(for: sticker))
                                            .aspectRatio(1, contentMode: .fit)
                                    }
                                    .padding()
                                    .frame(width: 280)
                                }
                        }
                    }
                }
                // So the keyboard the search field raised goes down when the grid is scrolled.
                .scrollDismissesKeyboard(.interactively)
            } else {
                switch model.libraryLoad {
                case .notLoaded:
                    Color.clear
                case .loaded:
                    LibraryEmptyStateView(needsSetUp: needsSetUp, compact: compact)
                case .failed:
                    LibraryLoadFailedView(compact: compact) {
                        Task { await model.reloadLibrary() }
                    }
                }
            }
        }
        .task {
            await model.reloadLibrary()
        }
    }
}
