import SwiftUI

/// Switches on `AppModel.route`. Idle is real (the library when expanded, then
/// Compose after "New sticker"; "New sticker" alone when compact), and so are
/// Generating and Error; Preview is a placeholder for a separate bead.
/// Settings is a sheet, opened by the library's "Set up OpenMoji" when there is
/// no key (FR-5), Compose's gear and the error's Settings button.
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
            Text("Preview")
        case .failed(let error):
            ErrorView(model: model, error: error) { showingSettings = true }
        }
    }
}
