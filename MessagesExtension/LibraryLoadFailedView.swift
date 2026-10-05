import SwiftUI

/// What the library shows when reading it failed and there is nothing already
/// on screen (tech spec §10): a short message and Try again, so a library that
/// couldn't be read isn't mistaken for an empty one (`AppModel.libraryLoad`).
///
/// One view for both presentation styles, like `LibraryEmptyStateView`:
/// expanded is a centred column, compact a short row for the small drawer.
/// Text styles only, so it follows Dynamic Type; if the content outgrows the
/// space (compact at the largest sizes) it scrolls. The icon is decoration, so
/// VoiceOver skips it and reads the heading; the message is also announced when
/// the view appears, since nothing else moves focus to it.
struct LibraryLoadFailedView: View {
    let compact: Bool
    /// Reads the library again.
    let onRetry: () -> Void

    private let message = "Couldn't load your stickers"

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .task {
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var content: some View {
        VStack(spacing: compact ? 12 : 16) {
            messageBlock
            Button(action: onRetry) {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Reads your stickers again")
        }
        .frame(maxWidth: compact ? .infinity : 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var messageBlock: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            Image(systemName: "exclamationmark.triangle")
                .font(compact ? .title : .largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(compact ? .headline : .title3)
                .multilineTextAlignment(compact ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
