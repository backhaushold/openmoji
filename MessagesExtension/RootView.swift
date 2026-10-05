import SwiftUI

/// Switches on `AppModel.route`: idle is the library when expanded, then
/// Compose after "New sticker" ("New sticker" alone when compact), then
/// Generating, Preview or Error. Settings is a sheet, opened by the library's
/// "Set up OpenMoji" when there is no key (FR-5), Compose's gear and the
/// error's Settings button.
struct RootView: View {
    let model: AppModel
    let settings: SettingsModel

    @State private var showingSettings = false

    var body: some View {
        content
            // However the sheet closes (Done or a swipe), pick up a key saved in
            // it: needs-key → idle, from "Set up OpenMoji" to "New sticker".
            .sheet(isPresented: $showingSettings, onDismiss: model.refreshKey) {
                SettingsView(model: settings) { showingSettings = false }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.route {
        case .compactHome:
            CompactHomeView(model: model, needsSetUp: false)
        case .compactSetUp:
            CompactHomeView(model: model, needsSetUp: true)
        case .library:
            LibraryView(model: model, needsSetUp: false) { showingSettings = true }
        case .librarySetUp:
            LibraryView(model: model, needsSetUp: true) { showingSettings = true }
        case .compose:
            ComposeView(model: model) { showingSettings = true }
        case .generating:
            GeneratingView(model: model)
        case .preview:
            if let sticker = model.previewSticker { PreviewView(model: model, sticker: sticker) }
        case .failed(let error):
            ErrorView(model: model, error: error) { showingSettings = true }
        }
    }
}
