import OpenMojiCore
import SwiftUI

/// The Error state (tech spec §6, §10; FR-22 to FR-24): the one plain message
/// for the failure, the prompt that was sent (kept, read-only), Try again, and
/// a way back to editing it. A rejected key (`.invalidKey`) adds Settings.
///
/// The message is `GenerationError.userMessage`, so the copy (including the
/// rate-limit seconds when OpenAI sent them) lives in one place, Core. Nothing
/// here touches the library: a failed generation has no sticker to save, and
/// `AppModel` holds no library (FR-24).
///
/// One view for both presentation styles, like `GeneratingView`: expanded is a
/// centred column, compact a short layout for the small drawer. Text entry and
/// the Settings sheet's key field only happen in expanded (§10), so in compact
/// "Edit description" and Settings first ask the host to expand.
///
/// Text styles only, so it follows Dynamic Type; if the content outgrows the
/// space (compact at the largest sizes) it scrolls, with the buttons reachable.
struct ErrorView: View {
    let model: AppModel
    let error: GenerationError
    /// Opens the Settings sheet (`RootView` owns it, as for Compose's gear).
    let onShowSettings: () -> Void

    private var compact: Bool { model.presentationStyle == .compact }

    private var message: String { error.userMessage ?? "Something went wrong." }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .padding()
        .task(id: message) {
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private var content: some View {
        VStack(spacing: compact ? 12 : 24) {
            messageBlock
            promptBox
            buttons
        }
        .frame(maxWidth: compact ? .infinity : 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var messageBlock: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            Image(systemName: "exclamationmark.triangle")
                .font(compact ? .title2 : .largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(compact ? .headline : .title3)
                .multilineTextAlignment(compact ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
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

    private var buttons: some View {
        VStack(spacing: compact ? 8 : 12) {
            if error.offersSettings {
                // The message points here, so Try again can't help until the key does.
                settingsButton.buttonStyle(.borderedProminent)
                tryAgainButton.buttonStyle(.bordered)
            } else {
                tryAgainButton.buttonStyle(.borderedProminent)
            }
            editButton.buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private var tryAgainButton: some View {
        Button { model.generate() } label: {
            Label("Try again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .disabled(!model.canGenerate)
        .accessibilityHint("Sends the same description again")
    }

    private var settingsButton: some View {
        Button {
            if compact { model.requestExpandedStyle() }
            onShowSettings()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity)
        }
        .accessibilityHint("Opens the OpenAI key settings")
    }

    private var editButton: some View {
        Button {
            model.dismissError()
            if compact { model.requestExpandedStyle() }
        } label: {
            Label("Edit description", systemImage: "pencil")
                .frame(maxWidth: .infinity)
        }
        .accessibilityHint("Goes back to your description so you can change it")
    }
}
