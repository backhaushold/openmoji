import Messages
import OpenMojiCore
import OSLog
import SwiftUI

/// The Preview state (tech spec §10; FR-11, FR-12): the processed sticker large
/// as an `MSStickerView`, the prompt it was made from, editable, and three
/// actions. Keep saves it to the library and returns to the library
/// (ADR-0017). Regenerate generates again from the prompt as it now reads, so
/// the user can reword it first, and writes nothing to the library. Discard
/// drops the sticker and returns to Compose with the prompt as it reads, also
/// writing nothing; it waits while a Keep is running.
///
/// The sticker is shown from a temp file written when the view appears and
/// removed when it goes (`PreviewFile`): nothing is in the library until Keep
/// (FR-24). Because it is an `MSStickerView`, a preview can already be dragged
/// onto a bubble. One layout for both presentation styles for now; it scrolls
/// when it outgrows the space (the keyboard, the largest text sizes). Text
/// styles only, so it follows Dynamic Type.
struct PreviewView: View {
    private static let log = Logger(subsystem: "com.backhaushold.openmoji", category: "PreviewView")

    let model: AppModel
    let sticker: ProcessedSticker

    @State private var stickerFile: URL?
    @State private var fileFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Your sticker")
                    .font(.title2)
                    .accessibilityAddTraits(.isHeader)
                stickerImage
                PromptField(model: model)
                if model.keepFailed { keepFailedMessage }
                buttons
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .task {
            do {
                stickerFile = try PreviewFile.write(sticker)
            } catch {
                Self.log.error("Could not write the preview file: \(error.localizedDescription, privacy: .public)")
                fileFailed = true
            }
        }
        .onDisappear {
            if let stickerFile { PreviewFile.remove(stickerFile) }
        }
        .onChange(of: model.keepFailed) { _, failed in
            if failed { AccessibilityNotification.Announcement(Self.keepFailedText).post() }
        }
    }

    private var stickerImage: some View {
        Group {
            if let stickerFile {
                PreviewStickerView(url: stickerFile, description: sticker.accessibilityText)
            } else if fileFailed {
                Text("Can't show the preview, but you can still keep it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: 360)
        .aspectRatio(1, contentMode: .fit)
    }

    private static let keepFailedText = "Couldn't save your sticker. Try Keep again."

    private var keepFailedMessage: some View {
        Text(Self.keepFailedText)
            .font(.callout)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button { Task { await model.keep() } } label: {
                Label("Keep", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isKeeping)
            .accessibilityHint("Saves the sticker to your library")

            Button { model.generate() } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canGenerate)
            .accessibilityHint("Makes a new sticker from the description above")

            Button(role: .destructive) { model.dismissPreview() } label: {
                Label("Discard", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isKeeping)
            .accessibilityHint("Throws this sticker away and goes back to the description")
        }
        .controlSize(.large)
    }
}

/// An `MSStickerView` for the previewed PNG, sized by its frame.
private struct PreviewStickerView: UIViewRepresentable {
    let url: URL
    let description: String

    func makeUIView(context: Context) -> MSStickerView {
        let view = MSStickerView()
        view.sticker = try? MSSticker(contentsOfFileURL: url, localizedDescription: description)
        view.isAccessibilityElement = true
        view.accessibilityLabel = description
        view.accessibilityTraits = .image
        return view
    }

    func updateUIView(_ view: MSStickerView, context: Context) {}
}
