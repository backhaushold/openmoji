import OpenMojiCore
import SwiftUI

/// The library grid (tech spec §10, FR-17): the kept stickers, newest first,
/// in a lazy grid that fills the space it is given. Shared by the expanded
/// landing screen (`LibraryView`) and the minimal compact layout
/// (`CompactHomeView`). It reads the library when it appears; whatever changes
/// the library later calls `AppModel.reloadLibrary()`.
///
/// Touch-and-hold on a cell opens a context menu with Delete (FR-19), and shows
/// the sticker's whole prompt above it, since the cell has no room for it.
///
/// With no stickers it shows the empty state (FR-20), which points at the
/// button the caller puts under the grid, once a read has succeeded; if the
/// read failed it shows a short error with Try again instead, so an unreadable
/// library isn't taken for an empty one. It stays blank until the first read
/// has finished (`AppModel.libraryLoad`), so it doesn't flash before the
/// stickers arrive; it goes away by itself once a Keep reloads the library and
/// `model.stickers` has an entry. Stickers already shown stay shown if a later
/// read fails.
struct StickerGridView: View {
    let model: AppModel
    /// No key: the button under the grid is "Set up OpenMoji", not "New sticker".
    let needsSetUp: Bool

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 12)]

    private var compact: Bool { model.presentationStyle == .compact }

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
                                } preview: {
                                    StickerPromptPreview(sticker: sticker, url: model.fileURL(for: sticker))
                                }
                        }
                    }
                }
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

/// What the context menu lifts for a sticker: the prompt it was made from, in
/// full (up to 200 characters, FR-6; the 150-scalar cut is only for VoiceOver),
/// above the sticker. Text styles only, so it follows Dynamic Type.
private struct StickerPromptPreview: View {
    let sticker: Sticker
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Text(sticker.prompt)
                .font(.body)
                .multilineTextAlignment(.center)
            StickerCell(sticker: sticker, url: url)
                .aspectRatio(1, contentMode: .fit)
        }
        .padding()
        .frame(width: 280)
    }
}
