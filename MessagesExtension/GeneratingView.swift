import SwiftUI

/// The Generating state (tech spec §10; FR-10): a progress indicator, "Making
/// your sticker…", the prompt being made (read-only) and Cancel. Cancel calls
/// `AppModel.cancel()`, which stops the request and returns to the prompt with
/// no error and the prompt intact.
///
/// One view for both presentation styles, so a generation keeps its state if
/// the user collapses or expands the app mid-way: expanded is a centred
/// column, compact a short layout that fits the small drawer. A generation
/// takes about 10 s at medium quality (M1 spike) and times out at 90 s (NFR-4),
/// so after 10 s it adds "Still working…".
///
/// Text styles only, so it follows Dynamic Type; if the content outgrows the
/// space (compact at the largest sizes) it scrolls, with Cancel still reachable.
struct GeneratingView: View {
    let model: AppModel

    @State private var stillWorking = false

    private static let stillWorkingDelay: Duration = .seconds(10)

    private var compact: Bool { model.presentationStyle == .compact }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .padding()
        .task {
            AccessibilityNotification.Announcement("Making your sticker").post()
            try? await Task.sleep(for: Self.stillWorkingDelay)
            guard !Task.isCancelled else { return }
            stillWorking = true
            AccessibilityNotification.Announcement("Still working").post()
        }
    }

    private var content: some View {
        VStack(spacing: compact ? 12 : 24) {
            status
            promptBox
            cancelButton
        }
        .frame(maxWidth: compact ? .infinity : 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var status: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            ProgressView()
                .controlSize(compact ? .regular : .extraLarge)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Making your sticker…")
                    .font(compact ? .headline : .title2)
                    .accessibilityAddTraits(.isHeader)
                if stillWorking {
                    Text("Still working…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
    }

    private var promptBox: some View {
        Text(model.prompt)
            .font(compact ? .callout : .body)
            .lineLimit(compact ? 2 : nil)
            .multilineTextAlignment(.center)
            .padding(compact ? 8 : 12)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Your description: \(model.prompt)")
    }

    private var cancelButton: some View {
        Button { model.cancel() } label: {
            Text("Cancel")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Stops making the sticker and keeps your description")
    }
}
