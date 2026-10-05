import SwiftUI

/// What the library shows with no stickers (tech spec §10, FR-20): a short
/// message that points at the button under the grid. That button is "New
/// sticker", or "Set up OpenMoji" when there is no key (FR-5, ADR-0017), and
/// the message names whichever one is there.
///
/// One view for both presentation styles, like `ErrorView`: expanded is a
/// centred column, compact a short row for the small drawer. Text styles only,
/// so it follows Dynamic Type; if the content outgrows the space (compact at
/// the largest sizes) it scrolls. The icon is decoration, so VoiceOver skips
/// it and reads the heading and the message.
struct LibraryEmptyStateView: View {
    /// No key: the button under the grid is "Set up OpenMoji".
    let needsSetUp: Bool
    let compact: Bool

    private var message: String {
        needsSetUp
            ? "Tap Set up OpenMoji to add your OpenAI key, then make your first sticker. It will show up here."
            : "Tap New sticker to describe your first one. It will show up here."
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            Image(systemName: "face.smiling")
                .font(compact ? .title : .largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: compact ? .leading : .center, spacing: 4) {
                Text("No stickers yet")
                    .font(compact ? .headline : .title3)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(compact ? .leading : .center)
        }
        .frame(maxWidth: compact ? .infinity : 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}
